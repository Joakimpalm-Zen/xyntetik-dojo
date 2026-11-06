import Darwin
import Foundation
import Testing
@testable import XHSCore

/// A folder with a config and a program, removed with the test.
private final class Rig {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)")
    var config: URL { dir.appendingPathComponent("relay") }
    var program: URL { dir.appendingPathComponent("tool") }

    init(script: String = "#!/bin/sh\nprintf '%s|' \"$RELAY_PANE\" \"$@\"\n") throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try script.write(to: program, atomically: true, encoding: .utf8)
        chmod(program.path, 0o755)
        try (program.path + "\n").write(to: config, atomically: true, encoding: .utf8)
        chmod(config.path, 0o644)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }
}

@Suite struct RelayConfigTests {
    @Test func noConfigIsOff() {
        let missing = URL(fileURLWithPath: "/no/such/relay")
        #expect(Relay.program(config: missing) == nil)
    }

    @Test func aGoodConfigNamesTheProgram() throws {
        let rig = try Rig()
        #expect(Relay.program(config: rig.config) == .success(rig.program.path))
    }

    @Test func aRelativePathIsRefused() throws {
        let rig = try Rig()
        try "tool\n".write(to: rig.config, atomically: true, encoding: .utf8)
        #expect(Relay.program(config: rig.config) == .failure("the relay program must be an absolute path"))
    }

    @Test func aProgramOthersCanWriteIsRefused() throws {
        let rig = try Rig()
        chmod(rig.program.path, 0o777)
        guard case .failure(let why)? = Relay.program(config: rig.config) else { Issue.record("not refused"); return }
        #expect(why.contains("writable"))
    }

    @Test func aConfigOthersCanWriteIsRefused() throws {
        let rig = try Rig()
        chmod(rig.config.path, 0o666)
        guard case .failure(let why)? = Relay.program(config: rig.config) else { Issue.record("not refused"); return }
        #expect(why.contains("writable"))
    }

    @Test func aProgramThatCannotRunIsRefused() throws {
        let rig = try Rig()
        chmod(rig.program.path, 0o644)
        guard case .failure(let why)? = Relay.program(config: rig.config) else { Issue.record("not refused"); return }
        #expect(why.contains("executable"))
    }

    @Test func aFolderIsNotAProgram() throws {
        let rig = try Rig()
        try (rig.dir.path + "\n").write(to: rig.config, atomically: true, encoding: .utf8)
        guard case .failure? = Relay.program(config: rig.config) else { Issue.record("not refused"); return }
    }
}

@Suite struct RelayWordsTests {
    @Test func wordsAreStrings() {
        #expect(Relay.words(["a", "b c"]) == .success(["a", "b c"]))
        #expect(Relay.words("a") == .failure("args must be a list of words"))
        #expect(Relay.words([1, 2]) == .failure("args must be a list of words"))
        #expect(Relay.words(nil) == .failure("args must be a list of words"))
    }

    @Test func thereMustBeAWordAndNotTooMany() {
        #expect(Relay.words([String]()) == .failure("nothing to relay"))
        guard case .failure = Relay.words(Array(repeating: "x", count: Relay.maxWords + 1)) else { Issue.record("not refused"); return }
        #expect(Relay.words(Array(repeating: "x", count: Relay.maxWords)) == .success(Array(repeating: "x", count: Relay.maxWords)))
    }

    @Test func aLongWordOrANulIsRefused() {
        guard case .failure = Relay.words([String(repeating: "x", count: Relay.maxWordBytes + 1)]) else { Issue.record("not refused"); return }
        guard case .failure = Relay.words(["a\0b"]) else { Issue.record("not refused"); return }
    }
}

@Suite struct RelayRunTests {
    private func run(_ rig: Rig, _ words: [String], pane: String = "p", timeout: TimeInterval = 5) async -> Relay.Outcome {
        await withCheckedContinuation { c in
            Relay.run(program: rig.program.path, words: words, pane: pane, timeout: timeout) { c.resume(returning: $0) }
        }
    }

    @Test func wordsReachTheProgramAsTheyAre() async throws {
        let out = await run(try Rig(), ["a b", "$(touch /tmp/relay-never)", "; rm -rf x", "`id`", "--flag"], pane: "the-pane")
        #expect(out.code == 0)
        #expect(out.stdout == "the-pane|a b|$(touch /tmp/relay-never)|; rm -rf x|`id`|--flag|")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/relay-never"))
    }

    @Test func theExitCodeAndStderrComeBack() async throws {
        let out = await run(try Rig(script: "#!/bin/sh\necho nope >&2\nexit 3\n"), ["x"])
        #expect(out.code == 3 && out.stderr == "nope\n" && !out.timedOut)
    }

    @Test func theEnvironmentIsMinimal() async throws {
        setenv("RELAY_TEST_SECRET", "leak", 1)
        defer { unsetenv("RELAY_TEST_SECRET") }
        let out = await run(try Rig(script: "#!/bin/sh\necho \"[$RELAY_TEST_SECRET][$DOJO_TOKEN]\"\n"), ["x"])
        #expect(out.stdout == "[][]\n")
    }

    @Test func stdinIsClosed() async throws {
        let out = await run(try Rig(script: "#!/bin/sh\ncat\necho done\n"), ["x"])
        #expect(out.stdout == "done\n")
    }

    @Test func aProgramThatHangsIsKilled() async throws {
        let started = Date()
        let out = await run(try Rig(script: "#!/bin/sh\nexec sleep 30\n"), ["x"], timeout: 0.3)
        #expect(out.timedOut && out.code != 0)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func aProgramThatIgnoresTerminationIsKilled() async throws {
        let started = Date()
        let out = await run(try Rig(script: "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n"), ["x"], timeout: 0.3)
        #expect(out.timedOut)
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test func outputIsCapped() async throws {
        let out = await run(try Rig(script: "#!/bin/sh\nhead -c 300000 /dev/zero | tr '\\0' x\n"), ["x"])
        #expect(out.code == 0 && out.stdout.utf8.count == Relay.maxOutputBytes && out.truncated)
    }
}

@Suite @MainActor struct RelayBusTests {
    let bus = Bus()
    let token: String

    init() {
        bus.submitDelay = 0
        token = bus.add(name: "remote-1", kind: .claude, io: MockIO())
    }

    private func ask(_ args: Any, token: String?) async -> (handled: Bool, status: Int, json: [String: Any]) {
        let body = try! JSONSerialization.data(withJSONObject: ["args": args])
        return await withCheckedContinuation { c in
            var answered = false
            let handled = bus.relay(path: "/relay", token: token, body: body) { status, data in
                answered = true
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                c.resume(returning: (true, status, json))
            }
            if !handled && !answered { c.resume(returning: (false, 0, [:])) }
        }
    }

    @Test func withNoConfigTheRouteIsNotThere() async {
        bus.relayConfig = URL(fileURLWithPath: "/no/such/relay")
        #expect(await ask(["x"], token: token).handled == false)
        let unknown = bus.handle(path: "/frobnicate", token: token, body: Data())
        let relay = bus.handle(path: "/relay", token: token, body: Data())
        #expect(relay.status == unknown.status)
        let text = String(decoding: relay.body, as: UTF8.self).replacingOccurrences(of: "'relay'", with: "'frobnicate'")
        #expect(text == String(decoding: unknown.body, as: UTF8.self))
    }

    @Test func withNoConfigSetTheRouteIsNotThere() async {
        #expect(await ask(["x"], token: token).handled == false)
    }

    @Test func otherRoutesAreNotTakenByTheRelay() async throws {
        let rig = try Rig()
        bus.relayConfig = rig.config
        #expect(bus.relay(path: "/panes", token: token, body: Data()) { _, _ in } == false)
    }

    @Test func thePaneNameComesFromTheToken() async throws {
        let rig = try Rig()
        bus.relayConfig = rig.config
        let out = await ask(["claim", "--as", "someone-else"], token: token)
        #expect(out.status == 200 && out.json["code"] as? Int == 0)
        #expect(out.json["stdout"] as? String == "remote-1|claim|--as|someone-else|")
    }

    @Test func aBadTokenRunsNothing() async throws {
        let rig = try Rig(script: "#!/bin/sh\ntouch \"$0.ran\"\n")
        bus.relayConfig = rig.config
        #expect(await ask(["x"], token: "wrong").status == 401)
        #expect(await ask(["x"], token: nil).status == 401)
        #expect(!FileManager.default.fileExists(atPath: rig.program.path + ".ran"))
    }

    @Test func aRefusedProgramRunsNothingAndSaysWhy() async throws {
        let rig = try Rig()
        chmod(rig.program.path, 0o777)
        bus.relayConfig = rig.config
        let out = await ask(["x"], token: token)
        #expect(out.status == 403 && (out.json["error"] as? String ?? "").contains("writable"))
    }

    @Test func badWordsRunNothing() async throws {
        let rig = try Rig()
        bus.relayConfig = rig.config
        #expect(await ask([1], token: token).status == 400)
    }

    @Test func oneRelayRunsAtATime() async throws {
        let rig = try Rig(script: "#!/bin/sh\nsleep 0.4\n")
        bus.relayConfig = rig.config
        async let first = ask(["x"], token: token)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = await ask(["y"], token: token)
        #expect(second.status == 429)
        #expect(await first.status == 200)
    }

    @Test func nothingIsTypedIntoAnyPane() async throws {
        let rig = try Rig()
        let io = MockIO()
        _ = bus.add(name: "other", kind: .claude, io: io)
        bus.relayConfig = rig.config
        _ = await ask(["x"], token: token)
        #expect(io.written.isEmpty)
    }
}

/// The whole path, over loopback HTTP, as the app wires it.
@Suite @MainActor struct RelayOverHTTPTests {
    private func served(_ bus: Bus) async throws -> BusServer {
        let server = try BusServer(port: 0) { path, token, body in bus.handle(path: path, token: token, body: body) }
        server.deferred = { path, token, body, reply in bus.relay(path: path, token: token, body: body, reply: reply) }
        let started: Error? = await withCheckedContinuation { c in server.start { c.resume(returning: $0) } }
        #expect(started == nil)
        return server
    }

    private func post(_ server: BusServer, _ op: String, _ args: [String: Any], token: String) async throws -> (Int, String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port!)/\(op)")!)
        request.httpMethod = "POST"
        request.httpBody = body(args)
        request.setValue(token, forHTTPHeaderField: "X-Dojo-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as! HTTPURLResponse).statusCode, String(decoding: data, as: UTF8.self))
    }

    @Test func withNoConfigRelayAnswersAsAnyUnknownOperationDoes() async throws {
        let bus = Bus()
        let token = bus.add(name: "a", kind: .claude, io: MockIO())
        bus.relayConfig = URL(fileURLWithPath: "/no/such/relay")
        let server = try await served(bus)
        defer { server.stop() }
        let relay = try await post(server, "relay", ["args": ["x"]], token: token)
        let unknown = try await post(server, "frobnicate", ["args": ["x"]], token: token)
        #expect(relay.0 == 404 && relay.0 == unknown.0)
        #expect(relay.1.replacingOccurrences(of: "relay", with: "frobnicate") == unknown.1)
    }

    @Test func aConfiguredRelayRunsAndTheBusStaysFreeMeanwhile() async throws {
        let rig = try Rig(script: "#!/bin/sh\nsleep 0.5\necho \"$RELAY_PANE $1\"\n")
        let bus = Bus()
        let token = bus.add(name: "a", kind: .claude, io: MockIO())
        bus.relayConfig = rig.config
        let server = try await served(bus)
        defer { server.stop() }
        async let slow = post(server, "relay", ["args": ["hello"]], token: token)
        try await Task.sleep(nanoseconds: 100_000_000)
        let started = Date()
        #expect(try await post(server, "panes", [:], token: token).0 == 200)
        #expect(Date().timeIntervalSince(started) < 0.3, "the bus waited for the relay")
        let result = try await slow
        #expect(result.0 == 200 && result.1.contains("a hello"))
    }
}

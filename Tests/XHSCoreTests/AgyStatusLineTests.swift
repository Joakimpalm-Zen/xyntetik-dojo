import Foundation
import Testing
@testable import XHSCore

/// D38: agy fires no hook for a permission ask. Its status-line command gets the session's state on every
/// change (agy docs, cli/statusline), with `tool_confirmation_pending` true while a tool confirmation dialog
/// shows. An agy pane runs Dojo's own status-line command (`dojo statusline agy`), which reports that to the
/// bus. Run for real here: the shim as agy runs it, with agy's JSON on stdin, against a bus served over
/// loopback HTTP.
@MainActor
@Suite struct AgyStatusLineTests {
    static let shim = repoRoot.appendingPathComponent("tools/dojo-mcp.py").path

    /// A status-line payload of the shape agy 1.5.9 documents, with `fields` on top.
    static func payload(_ fields: [String: Any]) -> String {
        var data: [String: Any] = [
            "conversation_id": "d38d38d3-8d38-4d38-8d38-d38d38d38d38", "cwd": "/home/tester/work", "product": "antigravity",
            "model": ["id": "gemini-3.8-flash-high", "display_name": "Gemini 3.8 Flash (High)", "effort": "high"],
            "context_window": ["context_window_size": 1_000_000, "used_percentage": 1.3],
            "quota": ["gemini-5h": ["remaining_fraction": 0.99, "reset_in_seconds": 17400]],
        ]
        data.merge(fields) { $1 }
        return String(decoding: try! JSONSerialization.data(withJSONObject: data), as: UTF8.self)
    }

    /// The shim's status line, run off the main actor so the bus can answer it. The test process stands in for
    /// the pane's agy, which runs the command as its child: an agy pane's environment names it in DOJO_AGY_PID.
    static func statusLine(_ stdin: String, environment: [String: String]) async -> (status: Int32, out: String) {
        let shim = Self.shim
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", shim, "statusline", "agy"]
                process.environment = environment
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return continuation.resume(returning: (-1, "")) }
                input.fileHandleForWriting.write(Data(stdin.utf8))
                try? input.fileHandleForWriting.close()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    /// Whether the pane reaches `state` within five seconds. The bus answers on the main actor, which the
    /// tests running beside this one can keep busy past the shim's one second: the shim has gone by then, and
    /// the bus handles its request when the main actor is free.
    static func settles(_ bus: Bus, _ name: String, at state: PaneState) async -> Bool {
        for _ in 0..<100 {
            if bus.info(name)?.state == state { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return bus.info(name)?.state == state
    }

    /// A folder of the test's own for what the status line keeps between runs.
    static func folder() -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agy-status-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func aConfirmationDialogPutsThePaneAtPromptAndTheAnswerTakesItBack() async throws {
        let bus = Bus()
        let token = bus.add(name: "agy-1", kind: .agy, io: MockIO(kind: .agy))
        let server = try BusServer(port: 0) { path, token, body in bus.handle(path: path, token: token, body: body) }
        let started: Error? = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        #expect(started == nil)
        defer { server.stop() }
        let port = try #require(server.port)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let tmp = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let pane = ["PATH": path, "DOJO_TOKEN": token, "DOJO_PORT": String(port), "DOJO_PANE": "agy-1", "TMPDIR": tmp,
                    "DOJO_HARNESS": "agy", "DOJO_AGY_PID": String(getpid())]
        func report(_ fields: [String: Any], _ environment: [String: String]? = nil) async -> String {
            let (status, out) = await Self.statusLine(Self.payload(fields), environment: environment ?? pane)
            #expect(status == 0)
            return out
        }

        // the control: the same flip from a command that tells the bus nothing leaves the pane as it was
        _ = await report(["agent_state": "working"], ["PATH": path, "TMPDIR": tmp])
        _ = await report(["agent_state": "tool_use", "tool_confirmation_pending": true], ["PATH": path, "TMPDIR": tmp])
        #expect(bus.info("agy-1")?.state == .starting)

        let line = await report(["agent_state": "working"])
        #expect(await Self.settles(bus, "agy-1", at: .running))
        #expect(line.hasPrefix("Usage: 5h 99% left") && line.hasSuffix(" | Model: Gemini 3.8 Flash (High) | Thinking: HIGH\n"))
        _ = await report(["agent_state": "tool_use", "tool_confirmation_pending": true])
        #expect(await Self.settles(bus, "agy-1", at: .prompt))
        // the owner answered: agy goes on with the tool, and then ends the turn
        _ = await report(["agent_state": "tool_use"])
        #expect(await Self.settles(bus, "agy-1", at: .running))
        _ = await report(["agent_state": "idle"])
        #expect(await Self.settles(bus, "agy-1", at: .idle))
    }

    /// Live on 2026-11-16: an agy run as a tool inside a Claude pane reported into that pane. Both ends now:
    /// that agy has no DOJO_HARNESS, so it tells the bus nothing; and the bus refuses agy's events for a pane
    /// of another kind, should they come, and records the refusal. The agy pane itself is as before.
    @Test func anAgyInsideAClaudePaneMovesNothing() async throws {
        let bus = Bus()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agy-refused-\(UUID().uuidString)")
        bus.record = BusRecord(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let claude = bus.add(name: "claude-1", kind: .claude, io: MockIO())
        let agy = bus.add(name: "agy-1", kind: .agy, io: MockIO(kind: .agy))
        bus.setState("claude-1", .running)
        let server = try BusServer(port: 0) { path, token, body in bus.handle(path: path, token: token, body: body) }
        let started: Error? = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        #expect(started == nil)
        defer { server.stop() }
        let port = try #require(server.port)
        let tmp = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        // the Claude pane's environment, as any process it starts inherits it
        let inClaude = ["PATH": path, "DOJO_TOKEN": claude, "DOJO_PORT": String(port), "DOJO_PANE": "claude-1", "TMPDIR": tmp]
        _ = await Self.statusLine(Self.payload(["agent_state": "idle"]), environment: inClaude)
        _ = await Self.statusLine(Self.payload(["agent_state": "tool_use", "tool_confirmation_pending": true]), environment: inClaude)
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(bus.info("claude-1")?.state == .running)
        #expect(bus.info("claude-1")?.model == "")
        // the bus's own end: an event marked agy's from a Claude pane is refused, and the record says so
        let refused = bus.handle(path: "/hook", token: claude, body: try JSONSerialization.data(withJSONObject:
            ["hook_event_name": "Stop", "model": "gemini-4-hydrogen-high", "harness": "agy"]))
        #expect(refused.status == 403)
        #expect(bus.info("claude-1")?.state == .running)
        #expect(bus.info("claude-1")?.model == "")
        let lines = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).flatMap {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        #expect(lines.contains { $0.contains("\"op\":\"hook\"") && $0.contains("refused") && $0.contains("claude-1") })
        // the agy pane is as before
        let inAgy = ["PATH": path, "DOJO_TOKEN": agy, "DOJO_PORT": String(port), "DOJO_PANE": "agy-1", "TMPDIR": tmp,
                     "DOJO_HARNESS": "agy", "DOJO_AGY_PID": String(getpid())]
        _ = await Self.statusLine(Self.payload(["agent_state": "tool_use", "tool_confirmation_pending": true]), environment: inAgy)
        #expect(await Self.settles(bus, "agy-1", at: .prompt))
    }

    /// An agy that does not send the field: no prompt from the status line. The composer guard, which
    /// types only into a composer it can see, keeps the bus out of the dialog (D35.1).
    @Test func anAgyWithoutTheFieldLeavesTheDialogToTheScreen() async throws {
        let bus = Bus()
        let token = bus.add(name: "agy-1", kind: .agy, io: MockIO(kind: .agy))
        let server = try BusServer(port: 0) { path, token, body in bus.handle(path: path, token: token, body: body) }
        let started: Error? = await withCheckedContinuation { continuation in
            server.start { continuation.resume(returning: $0) }
        }
        #expect(started == nil)
        defer { server.stop() }
        let port = try #require(server.port)
        let tmp = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let pane = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "DOJO_TOKEN": token,
                    "DOJO_PORT": String(port), "DOJO_PANE": "agy-1", "TMPDIR": tmp, "DOJO_HARNESS": "agy", "DOJO_AGY_PID": String(getpid())]
        let (status, _) = await Self.statusLine(Self.payload(["agent_state": "tool_use"]), environment: pane)
        #expect(status == 0)
        #expect(await Self.settles(bus, "agy-1", at: .running))
        #expect(bus.info("agy-1")?.state != .prompt)
    }
}

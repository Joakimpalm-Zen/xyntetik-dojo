import Foundation
import Testing
@testable import XHSCore

@MainActor
@Suite struct BusTests {
    let bus = Bus()
    let senderIO = MockIO()
    let targetIO = MockIO()
    let senderToken: String
    let targetToken: String

    init() {
        bus.submitDelay = 0
        senderToken = bus.add(name: "claude-1", kind: .claude, io: senderIO)
        targetToken = bus.add(name: "codex-1", kind: .codex, host: "box", io: targetIO)
    }

    func call(_ op: String, _ args: [String: Any] = [:], token: String? = nil) -> (Int, [String: Any]) {
        let r = bus.handle(path: "/" + op, token: token ?? senderToken, body: body(args))
        return (r.status, json(r.body))
    }

    func hook(_ token: String, _ event: String, _ extra: [String: Any] = [:]) {
        var args = extra
        args["hook_event_name"] = event
        let r = bus.handle(path: "/hook", token: token, body: body(args))
        #expect(r.status == 200)
        #expect(r.body.isEmpty)
    }

    @Test func requestsNeedAKnownToken() {
        #expect(bus.handle(path: "/panes", token: nil, body: Data()).status == 401)
        #expect(bus.handle(path: "/panes", token: "nope", body: Data()).status == 401)
        #expect(call("bogus").0 == 404)
        #expect(bus.handle(path: "/send", token: senderToken, body: Data("[1]".utf8)).status == 400)
    }

    @Test func panesListsEveryPaneAndTheCaller() {
        let (status, result) = call("panes")
        #expect(status == 200)
        #expect(result["you"] as? String == "claude-1")
        let panes = result["panes"] as? [[String: Any]] ?? []
        #expect(panes.map { $0["name"] as? String } == ["claude-1", "codex-1"])
        #expect(panes[1]["host"] as? String == "box")
        #expect(panes[1]["state"] as? String == "starting")
    }

    @Test func sendToIdlePaneTypesPrefixedLineAndEnter() {
        hook(targetToken, "SessionStart")
        let (status, result) = call("send", ["pane": "codex-1", "text": "please review"])
        #expect(status == 200)
        #expect(result["delivered"] as? Bool == true)
        #expect(targetIO.typed == "[from: claude-1] please review\r")
        #expect(targetIO.written.last == Delivery.enter)
        #expect(bus.info("codex-1")?.state == .running)
    }

    @Test func neverTypesIntoAPromptQueuesUntilIdle() {
        hook(targetToken, "SessionStart")
        hook(targetToken, "UserPromptSubmit")
        hook(targetToken, "PermissionRequest")
        let (status, result) = call("send", ["pane": "codex-1", "text": "yes"])
        #expect(status == 200)
        #expect(result["delivered"] as? Bool == false)
        #expect(result["state"] as? String == "prompt")
        #expect(result["queued"] as? Int == 1)
        #expect((result["note"] as? String)?.contains("never types into a prompt") == true)
        #expect(targetIO.written.isEmpty)
        bus.tick()
        hook(targetToken, "PostToolUse")
        #expect(targetIO.written.isEmpty)
        hook(targetToken, "Notification", ["notification_type": "permission_prompt"])
        bus.tick()
        #expect(targetIO.written.isEmpty)
        hook(targetToken, "Stop")
        #expect(targetIO.typed == "[from: claude-1] yes\r")
        #expect(bus.info("codex-1")?.queued == 0)
    }

    @Test func startingPaneQueuesUntilSessionStart() {
        _ = call("send", ["pane": "codex-1", "text": "hello"])
        #expect(targetIO.written.isEmpty)
        hook(targetToken, "SessionStart")
        #expect(targetIO.typed == "[from: claude-1] hello\r")
    }

    @Test func runningPaneQueues() {
        hook(targetToken, "UserPromptSubmit")
        let (_, result) = call("send", ["pane": "codex-1", "text": "later"])
        #expect(result["delivered"] as? Bool == false)
        #expect(result["state"] as? String == "running")
        #expect(targetIO.written.isEmpty)
    }

    @Test func oneMessagePerIdle() {
        hook(targetToken, "UserPromptSubmit")
        _ = call("send", ["pane": "codex-1", "text": "one"])
        _ = call("send", ["pane": "codex-1", "text": "two"])
        hook(targetToken, "Stop")
        #expect(targetIO.typed == "[from: claude-1] one\r")
        #expect(bus.info("codex-1")?.state == .running)
        bus.tick()
        #expect(targetIO.typed == "[from: claude-1] one\r")
        hook(targetToken, "UserPromptSubmit")
        hook(targetToken, "Stop")
        #expect(targetIO.typed == "[from: claude-1] one\r[from: claude-1] two\r")
    }

    @Test func holdsWhileTheOwnerTypes() {
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        hook(targetToken, "SessionStart")
        bus.noteOwnerInput("codex-1")
        let (_, result) = call("send", ["pane": "codex-1", "text": "wait"])
        #expect(result["delivered"] as? Bool == false)
        clock += 1
        bus.tick()
        #expect(targetIO.written.isEmpty)
        clock += 3
        bus.tick()
        #expect(targetIO.typed == "[from: claude-1] wait\r")
    }

    @Test func bracketedPasteKeepsLinesTogether() {
        targetIO.bracketedPasteEnabled = true
        hook(targetToken, "SessionStart")
        _ = call("send", ["pane": "codex-1", "text": "line 1\nline 2"])
        #expect(targetIO.typed == "\u{1b}[200~[from: claude-1] line 1\nline 2\u{1b}[201~\r")
    }

    @Test func controlSequencesCannotBreakOutOfTheMessage() {
        targetIO.bracketedPasteEnabled = true
        hook(targetToken, "SessionStart")
        _ = call("send", ["pane": "codex-1", "text": "a\u{1b}[201~\ry\u{1b}[200~"])
        #expect(targetIO.typed == "\u{1b}[200~[from: claude-1] a[201~\ny[200~\u{1b}[201~\r")
    }

    @Test func sendErrors() {
        #expect(call("send", ["pane": "nobody", "text": "x"]).0 == 404)
        #expect(call("send", ["text": "x"]).0 == 404)
        #expect(call("send", ["pane": "codex-1", "text": " \u{1b} "]).0 == 400)
        #expect(call("send", ["pane": "codex-1", "text": String(repeating: "x", count: Bus.maxMessageLength + 1)]).0 == 413)
        bus.setState("codex-1", .exited)
        #expect(call("send", ["pane": "codex-1", "text": "x"]).0 == 409)
    }

    @Test func readReturnsTheLastLines() {
        targetIO.screen = "one\ntwo  \nthree\n\n   \n"
        let (status, result) = call("read", ["pane": "codex-1", "lines": 2])
        #expect(status == 200)
        #expect(result["text"] as? String == "two\nthree")
        #expect(call("read", ["pane": "codex-1"]).1["text"] as? String == "one\ntwo\nthree")
        #expect(call("read", ["pane": "codex-1", "lines": 0]).1["text"] as? String == "three")
    }

    @Test func stateReportsQueueAndModel() {
        hook(targetToken, "SessionStart", ["model": "gpt-x"])
        hook(targetToken, "UserPromptSubmit")
        _ = call("send", ["pane": "codex-1", "text": "q"])
        let (_, result) = call("state", ["pane": "codex-1"])
        #expect(result["state"] as? String == "running")
        #expect(result["queued"] as? Int == 1)
        #expect(result["model"] as? String == "gpt-x")
        #expect(result["kind"] as? String == "codex")
    }

    @Test func idleNotificationReleasesAPaneLeftAtPrompt() {
        hook(targetToken, "PermissionRequest")
        _ = call("send", ["pane": "codex-1", "text": "after"])
        #expect(targetIO.written.isEmpty)
        hook(targetToken, "Notification", ["notification_type": "idle_prompt"])
        #expect(targetIO.typed == "[from: claude-1] after\r")
    }

    @Test func runningPaneWithAStillScreenIsIdleAgain() {
        // A turn that ends without a Stop hook (usage limit, lost hook) must not hold messages forever.
        var clock = Date(timeIntervalSince1970: 1_000)
        bus.now = { clock }
        hook(targetToken, "SessionStart")
        hook(targetToken, "UserPromptSubmit")
        targetIO.screen = "Working (1s)"
        call("send", ["pane": "codex-1", "text": "hi"])
        #expect(bus.info("codex-1")?.state == .running)
        #expect(targetIO.written.isEmpty)
        for s in 1...14 {
            clock = clock.addingTimeInterval(1)
            if s < 6 { targetIO.screen = "Working (\(s)s)" }
            bus.tick()
            #expect(bus.info("codex-1")?.state == .running, "second \(s)")
        }
        // 5 seconds of change, then still: idle after 15 quiet seconds, not before.
        for _ in 15...19 { clock = clock.addingTimeInterval(1); bus.tick() }
        #expect(bus.info("codex-1")?.state == .running)
        clock = clock.addingTimeInterval(1); bus.tick()
        #expect(bus.info("codex-1")?.state == .idle || bus.info("codex-1")?.state == .running)
        clock = clock.addingTimeInterval(1); bus.tick()
        #expect(targetIO.typed.contains("[from: claude-1] hi"))
        #expect(bus.info("codex-1")?.queued == 0)
    }

    @Test func hooksRestartTheQuietClockAndPromptIsNeverTimedOut() {
        var clock = Date(timeIntervalSince1970: 1_000)
        bus.now = { clock }
        hook(targetToken, "SessionStart")
        hook(targetToken, "UserPromptSubmit")
        targetIO.screen = "still"
        for _ in 1...10 { clock = clock.addingTimeInterval(1); bus.tick() }
        hook(targetToken, "PostToolUse")
        for _ in 1...10 { clock = clock.addingTimeInterval(1); bus.tick() }
        #expect(bus.info("codex-1")?.state == .running)
        hook(targetToken, "PermissionRequest")
        for _ in 1...60 { clock = clock.addingTimeInterval(1); bus.tick() }
        #expect(bus.info("codex-1")?.state == .prompt)
    }

    @Test func removedPaneIsGone() {
        bus.remove("codex-1")
        #expect(bus.names == ["claude-1"])
        #expect(bus.handle(path: "/panes", token: targetToken, body: Data()).status == 401)
    }

    @Test func tokensAreUniqueAndLong() {
        let a = Bus.newToken(), b = Bus.newToken()
        #expect(a != b)
        #expect(a.count == 48)
    }
}

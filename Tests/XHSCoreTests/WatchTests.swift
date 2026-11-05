import Foundation
import Testing
@testable import XHSCore

/// One pane asks to hear when another stops: one notice per request, under the usual delivery rules.
@Suite @MainActor struct WatchTests {
    let bus = Bus()
    let askerIO = MockIO()
    let targetIO = MockIO()
    let asker: String
    let target: String

    init() {
        bus.submitDelay = 0
        asker = bus.add(name: "asker", kind: .claude, io: askerIO)
        target = bus.add(name: "target", kind: .codex, host: "box", io: targetIO)
        hook(asker, "SessionStart")
        hook(target, "SessionStart")
    }

    private func hook(_ token: String, _ event: String) {
        _ = bus.handle(path: "/hook", token: token, body: body(["hook_event_name": event]))
    }

    private func watch(_ pane: String = "target", token: String? = nil) -> (Int, [String: Any]) {
        let r = bus.handle(path: "/watch", token: token ?? asker, body: body(["pane": pane]))
        return (r.status, json(r.body))
    }

    @Test func itHearsOnceWhenTheTargetGoesIdle() {
        hook(target, "UserPromptSubmit")
        #expect(watch().0 == 200)
        #expect(askerIO.typed.isEmpty)
        hook(target, "Stop")
        #expect(askerIO.typed.contains("[from: target] Bus notice: target finished its turn."))
        let heard = askerIO.typed
        hook(target, "UserPromptSubmit")
        hook(target, "Stop")
        #expect(askerIO.typed == heard)
    }

    /// Runs the still-screen rule to its end on a running target.
    private func stillScreen(_ advance: () -> Void) {
        bus.tick()
        advance()
        bus.tick()
        advance()
        bus.tick()
    }

    @Test func aStillScreenDuringAHookReportedTurnSaysOnlyThat() {
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        hook(target, "UserPromptSubmit")
        _ = watch()
        stillScreen { clock += 60 }
        #expect(bus.info("target")?.state == .idle)
        #expect(askerIO.typed.contains("Bus notice: target looks idle: its screen has been still for 15 seconds, but no hook has reported the end of its turn."))
        #expect(!askerIO.typed.contains("finished its turn"))
    }

    @Test func watchingAgainAfterThatHearsTheRealFinish() {
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        hook(target, "UserPromptSubmit")
        _ = watch()
        stillScreen { clock += 60 }
        _ = watch()
        hook(target, "Stop")
        #expect(askerIO.typed.contains("Bus notice: target finished its turn."))
    }

    @Test func aPaneWithNoHookReportedTurnIsPlainlyIdle() {
        bus.setState("target", .running)
        _ = watch()
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        stillScreen { clock += 60 }
        #expect(askerIO.typed.contains("Bus notice: target is idle."))
        #expect(!askerIO.typed.contains("looks idle"))
    }

    @Test func aPromptCounts() {
        hook(target, "UserPromptSubmit")
        _ = watch()
        hook(target, "PermissionRequest")
        #expect(askerIO.typed.contains("Bus notice: target is at a prompt."))
    }

    @Test func theReplySaysHowTheTargetIsNow() {
        let (status, reply) = watch()
        #expect(status == 200)
        #expect(reply["state"] as? String == "idle")
        #expect(askerIO.typed.isEmpty)
    }

    @Test func askingTwiceIsOneRequest() {
        hook(target, "UserPromptSubmit")
        _ = watch()
        _ = watch()
        hook(target, "Stop")
        #expect(askerIO.typed.components(separatedBy: "Bus notice").count == 2)
    }

    @Test func anExitEndsTheRequestWithAMessage() {
        hook(target, "UserPromptSubmit")
        _ = watch()
        bus.setState("target", .exited)
        #expect(askerIO.typed.contains("Bus notice: target has exited."))
    }

    @Test func aClosedTargetEndsTheRequestWithAMessage() {
        _ = watch()
        bus.remove("target")
        #expect(askerIO.typed.contains("Bus notice: target was closed."))
    }

    @Test func aClosedAskerDropsItsRequest() {
        hook(target, "UserPromptSubmit")
        _ = watch()
        bus.remove("asker")
        hook(target, "Stop")
        #expect(askerIO.typed.isEmpty)
    }

    @Test func aRequestExpiresAfterTwelveHoursWithAMessage() {
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        _ = watch()
        clock += 12 * 3600 - 1
        bus.tick()
        #expect(askerIO.typed.isEmpty)
        clock += 2
        bus.tick()
        #expect(askerIO.typed.contains("Bus notice: nothing from target in 12 hours; the request is dropped."))
        hook(target, "UserPromptSubmit")
        hook(target, "Stop")
        #expect(askerIO.typed.components(separatedBy: "Bus notice").count == 2)
    }

    @Test func theNoticeWaitsLikeAnyMessageWhileTheAskerIsAtAPrompt() {
        hook(target, "UserPromptSubmit")
        _ = watch()
        hook(asker, "PermissionRequest")
        hook(target, "Stop")
        #expect(askerIO.typed.isEmpty)
        #expect(bus.info("asker")?.queued == 1)
        hook(asker, "Stop")
        #expect(askerIO.typed.contains("Bus notice: target finished its turn."))
    }

    @Test func thereIsNoWatchingYourselfOrAPaneThatHasExited() {
        #expect(watch("asker").0 == 400)
        bus.setState("target", .exited)
        #expect(watch().0 == 409)
        #expect(watch("nobody").0 == 404)
    }
}

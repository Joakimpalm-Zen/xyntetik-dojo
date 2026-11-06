import Foundation
import Testing
@testable import XHSCore

/// The signal behind the notifications, the ring and the unseen mark: hook-reported only, once per event.
@Suite @MainActor struct AttentionTests {
    /// The bus holds a pane's io weakly.
    private let io = MockIO()

    private func setup(kind: HarnessKind = .claude) -> (Bus, String, () -> [String]) {
        let bus = Bus()
        bus.submitDelay = 0
        var fired: [String] = []
        bus.onAttention = { name, attention in fired.append("\(name) \(attention)") }
        let token = bus.add(name: "a", kind: kind, io: io)
        return (bus, token, { fired })
    }

    private func hook(_ bus: Bus, _ token: String, _ event: String, _ extra: [String: Any] = [:]) {
        var args = extra
        args["hook_event_name"] = event
        _ = bus.handle(path: "/hook", token: token, body: body(args))
    }

    @Test func aPromptFiresOnceThoughTwoHooksReportIt() {
        let (bus, token, fired) = setup()
        hook(bus, token, "UserPromptSubmit")
        hook(bus, token, "PermissionRequest")
        hook(bus, token, "Notification", ["notification_type": "permission_prompt"])
        #expect(fired() == ["a prompt"])
    }

    @Test func aSecondPromptInTheTurnFiresAgain() {
        let (bus, token, fired) = setup()
        hook(bus, token, "UserPromptSubmit")
        hook(bus, token, "PermissionRequest")
        hook(bus, token, "PostToolUse")
        hook(bus, token, "PermissionRequest")
        #expect(fired() == ["a prompt", "a prompt"])
    }

    @Test func aTurnFinishesOnceThoughStopComesTwice() {
        let (bus, token, fired) = setup()
        hook(bus, token, "UserPromptSubmit")
        hook(bus, token, "Stop")
        hook(bus, token, "Stop")
        hook(bus, token, "Notification", ["notification_type": "idle_prompt"])
        #expect(fired() == ["a finished"])
    }

    @Test func aSessionStartIsNoFinish() {
        let (bus, token, fired) = setup()
        hook(bus, token, "SessionStart")
        #expect(fired().isEmpty)
    }

    @Test func theStillScreenRuleAloneFiresNothing() {
        let (bus, token, fired) = setup()
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        hook(bus, token, "UserPromptSubmit")
        bus.tick()
        clock += 60
        bus.tick()
        clock += 60
        bus.tick()
        #expect(bus.info("a")?.state == .idle)
        #expect(fired().isEmpty)
    }

    @Test func aStopAfterTheStillScreenRuleStillReportsTheFinish() {
        let (bus, token, fired) = setup()
        var clock = Date(timeIntervalSince1970: 1000)
        bus.now = { clock }
        hook(bus, token, "UserPromptSubmit")
        bus.tick()
        clock += 60
        bus.tick()
        clock += 60
        bus.tick()
        #expect(bus.info("a")?.state == .idle)
        #expect(fired().isEmpty)
        hook(bus, token, "Stop")
        #expect(fired() == ["a finished"])
    }
}

@Suite struct SeenTests {
    @Test func aPaneIsViewedOnlyWithTheKeysAndTheAppInFront() {
        #expect(Seen.viewed(active: true, keys: "a", pane: "a"))
        #expect(!Seen.viewed(active: true, keys: "b", pane: "a"))
        #expect(!Seen.viewed(active: false, keys: "a", pane: "a"))
        #expect(!Seen.viewed(active: true, keys: nil, pane: "a"))
    }

    @Test func aMinimizedWindowIsNotInFrontThoughItsAppIsActive() {
        #expect(Seen.inFront(active: true, windowOnScreen: true))
        #expect(!Seen.inFront(active: true, windowOnScreen: false))
        #expect(!Seen.inFront(active: false, windowOnScreen: true))
        #expect(Seen.notifies(active: Seen.inFront(active: true, windowOnScreen: false), shown: "a", pane: "a"))
    }

    @Test func nothingNotifiesForAPaneOnTheScreenInFront() {
        #expect(!Seen.notifies(active: true, shown: nil, pane: "a"))
        #expect(!Seen.notifies(active: true, shown: "a", pane: "a"))
    }

    @Test func aPaneBehindAnotherTabOrAnotherAppNotifies() {
        #expect(Seen.notifies(active: true, shown: "b", pane: "a"))
        #expect(Seen.notifies(active: false, shown: "a", pane: "a"))
        #expect(Seen.notifies(active: false, shown: nil, pane: "a"))
    }
}

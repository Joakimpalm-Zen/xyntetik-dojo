import AppKit
import Foundation
import Testing
@testable import XHSApp
@testable import XHSCore

/// D48 / PR #118 Probe B: when the owner queued an earlier prompt (not a bus paste), then typed a delayed
/// draft and pressed Enter (e.g., to accept completion), the earlier prompt's `UserPromptSubmit` hook must not
/// clear `ownerTypedUnproven` and let a capped bus message press Enter on the owner's delayed draft.
@MainActor @Suite struct D48QueuedOwnerSubmitTests {
    private static let sweepDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("sweep-2026-11-17")

    @MainActor private final class SpyIO: PaneIO {
        let pane: TerminalPane
        var writes: [[UInt8]] = []

        init(name: String = "worker", cols: Int, rows: Int) {
            _ = NSApplication.shared
            pane = TerminalPane(name: name)
            pane.resize(cols: cols, rows: rows)
        }

        var pasteCount: Int { writes.filter { $0 != Delivery.enter }.count }
        var enterCount: Int { writes.filter { $0 == Delivery.enter }.count }
        func showBytes(_ data: Data) { pane.show(Array(data)) }
        func write(_ bytes: [UInt8]) { writes.append(bytes) }
        func screenText() -> String { pane.screenText() }
        func visibleText() -> String { pane.visibleText() }
        func liveScreen() -> PaneScreen { pane.liveScreen() }
        func usedCells(last count: Int) -> [Int]? { pane.usedCells(last: count) }
        var columns: Int { pane.columns }
        var bracketedPasteEnabled: Bool { pane.bracketedPasteEnabled }
    }

    @MainActor private struct Rig {
        let bus: Bus
        let io: SpyIO
        let sender: String
        let worker: String
        let step: (TimeInterval) -> Void
        let fire: () -> Void

        func hook(_ event: String, prompt: String? = nil) throws {
            var payload: [String: Any] = ["hook_event_name": event]
            if let prompt { payload["prompt"] = prompt }
            let body = try JSONSerialization.data(withJSONObject: payload)
            _ = bus.handle(path: "/hook", token: worker, body: body)
        }

        func send(_ text: String) throws -> [String: Any] {
            let body = try JSONSerialization.data(withJSONObject: ["pane": "worker", "text": text])
            let reply = bus.handle(path: "/send", token: sender, body: body)
            return ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]) ?? [:]
        }
    }

    private static func makeRig(cols: Int, rows: Int) -> Rig {
        let bus = Bus()
        var now = Date(timeIntervalSince1970: 1_793_000_000)
        bus.now = { now }
        var pending: [(Date, () -> Void)] = []
        bus.schedule = { delay, work in pending.append((now.addingTimeInterval(delay), work)) }
        bus.submitDelay = 0.15
        let io = SpyIO(cols: cols, rows: rows)
        let sender = bus.add(name: "probe", kind: .claude, io: SpyIO(name: "probe", cols: cols, rows: rows))
        let worker = bus.add(name: "worker", kind: .claude, io: io)
        _ = bus.handle(path: "/hook", token: worker,
                       body: try! JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart"]))
        return Rig(
            bus: bus,
            io: io,
            sender: sender,
            worker: worker,
            step: { now = now.addingTimeInterval($0) },
            fire: {
                let items = pending
                pending.removeAll()
                for (due, work) in items {
                    if due > now { now = due }
                    work()
                }
            }
        )
    }

    private static func loadCappedCase() throws -> (before: Data, after: Data, payload: String, cols: Int, rows: Int) {
        let id = "claude-105x14-short-draft-s300"
        let bytes = try Data(contentsOf: sweepDir.appendingPathComponent("\(id).bin"))
        let manifest = try JSONDecoder().decode(
            [D43SweepScreensTests.SweepCase].self,
            from: Data(contentsOf: sweepDir.appendingPathComponent("manifest.json"))
        )
        let entry = try #require(manifest.first { $0.id == id })
        let pasted = String(decoding: try Data(contentsOf: sweepDir.appendingPathComponent("\(id).txt")), as: UTF8.self)
        let payload = D43SweepScreensTests.sendPayload(from: pasted)
        return (
            Data(bytes.prefix(entry.beforeOffset)),
            Data(bytes[entry.beforeOffset..<entry.afterOffset]),
            payload,
            entry.cols,
            entry.rows
        )
    }

    @Test func earlierQueuedOwnerSubmitHookMustNotClearOwnerTypedUnproven() throws {
        let fx = try Self.loadCappedCase()
        let rig = Self.makeRig(cols: fx.cols, rows: fx.rows)
        rig.io.showBytes(fx.before)
        rig.bus.setState("worker", .running)

        // 1. Owner queued an earlier prompt ("earlier owner prompt") whose submit hook has not arrived yet.
        rig.bus.noteOwnerInput("worker", .text)
        rig.bus.noteOwnerInput("worker", .submit)

        // 2. While that earlier prompt is queued and echo is delayed (screen looks empty), the owner types a
        //    new draft ("later draft") and hits Enter to accept completion.
        rig.bus.noteOwnerInput("worker", .text)
        rig.bus.noteOwnerInput("worker", .submit)

        // 3. The earlier queued prompt's UserPromptSubmit arrives: it MUST NOT clear ownerTypedUnproven.
        try rig.hook("UserPromptSubmit", prompt: "earlier owner prompt")
        try rig.hook("Stop")
        rig.step(4)
        rig.bus.tick()

        // 4. Next capped message pastes onto delayed draft; head is hidden -> Enter MUST NOT be sent.
        let reply = try rig.send(fx.payload)
        #expect(reply["delivered"] as? Bool == true)
        #expect(rig.io.pasteCount == 1)
        rig.io.showBytes(fx.after)
        rig.fire()
        for _ in 0..<5 {
            rig.step(1)
            rig.bus.tick()
        }
        #expect(rig.io.enterCount == 0, "earlier owner queued prompt hook cleared ownerTypedUnproven and sent Enter")
        #expect(rig.bus.info("worker")?.needsOwnerEnter == true)

        // Positive control: when both queued prompts' submit hooks have arrived, the capped message sends Enter.
        let control = Self.makeRig(cols: fx.cols, rows: fx.rows)
        control.io.showBytes(fx.before)
        control.bus.setState("worker", .running)
        control.bus.noteOwnerInput("worker", .text)
        control.bus.noteOwnerInput("worker", .submit)
        control.bus.noteOwnerInput("worker", .text)
        control.bus.noteOwnerInput("worker", .submit)
        try control.hook("UserPromptSubmit", prompt: "earlier owner prompt")
        try control.hook("UserPromptSubmit", prompt: "later draft")
        try control.hook("Stop")
        control.step(4)
        control.bus.tick()
        let controlReply = try control.send(fx.payload)
        #expect(controlReply["delivered"] as? Bool == true)
        control.io.showBytes(fx.after)
        control.fire()
        for _ in 0..<5 {
            control.step(1)
            control.bus.tick()
        }
        #expect(control.io.enterCount == 1)
        #expect(control.bus.info("worker")?.needsOwnerEnter == false)
    }

    @Test func byteTrackedEarlierQueuedPromptHoldsWhileMatchingLatestDraftClears() throws {
        let fx = try Self.loadCappedCase()
        let rig = Self.makeRig(cols: fx.cols, rows: fx.rows)
        rig.io.showBytes(fx.before)
        rig.bus.setState("worker", .running)

        // Bus did not observe the earlier prompt's keystrokes (e.g., queued before Bus attached or from history);
        // it only sees the owner's delayed draft bytes + Enter.
        rig.bus.noteOwnerInput("worker", bytes: Array("later draft text".utf8)[...])
        rig.bus.noteOwnerInput("worker", bytes: [0x0D][...])

        // Earlier queued prompt's UserPromptSubmit disagrees with "later draft text": MUST NOT clear.
        try rig.hook("UserPromptSubmit", prompt: "unseen earlier prompt")
        try rig.hook("Stop")
        rig.step(4)
        rig.bus.tick()

        let blocked = try rig.send(fx.payload)
        #expect(blocked["delivered"] as? Bool == true)
        #expect(rig.io.pasteCount == 1)
        rig.io.showBytes(fx.after)
        rig.fire()
        for _ in 0..<5 {
            rig.step(1)
            rig.bus.tick()
        }
        #expect(rig.io.enterCount == 0)
        #expect(rig.bus.info("worker")?.needsOwnerEnter == true)

        // Fresh control where the matching latest draft submit hook arrives: MUST clear and send Enter.
        let matching = Self.makeRig(cols: fx.cols, rows: fx.rows)
        matching.io.showBytes(fx.before)
        matching.bus.setState("worker", .running)
        matching.bus.noteOwnerInput("worker", bytes: Array("later draft text".utf8)[...])
        matching.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try matching.hook("UserPromptSubmit", prompt: "unseen earlier prompt")
        try matching.hook("UserPromptSubmit", prompt: "later draft text")
        try matching.hook("Stop")
        matching.step(4)
        matching.bus.tick()

        let cleared = try matching.send(fx.payload)
        #expect(cleared["delivered"] as? Bool == true)
        matching.io.showBytes(fx.after)
        matching.fire()
        for _ in 0..<5 {
            matching.step(1)
            matching.bus.tick()
        }
        #expect(matching.io.enterCount == 1)
        #expect(matching.bus.info("worker")?.needsOwnerEnter == false)
    }

    @Test func completionEnterTabAndBackspaceEditStillClearOnMatchingSubmit() throws {
        let fx = try Self.loadCappedCase()

        // 1. Backspace edits exact byte-tracked draft text cleanly so matching UserPromptSubmit still clears.
        let edited = Self.makeRig(cols: fx.cols, rows: fx.rows)
        edited.io.showBytes(fx.before)
        edited.bus.setState("worker", .running)
        edited.bus.noteOwnerInput("worker", bytes: Array("hello!".utf8)[...])
        edited.bus.noteOwnerInput("worker", bytes: [0x7F][...])
        edited.bus.noteOwnerInput("worker", bytes: Array(" world".utf8)[...])
        edited.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        // An unrelated unseen prompt hook still must not clear "hello world".
        try edited.hook("UserPromptSubmit", prompt: "unrelated earlier prompt")
        try edited.hook("UserPromptSubmit", prompt: "hello world")
        try edited.hook("Stop")
        edited.step(4)
        edited.bus.tick()
        _ = try edited.send(fx.payload)
        edited.io.showBytes(fx.after)
        edited.fire()
        for _ in 0..<5 {
            edited.step(1)
            edited.bus.tick()
        }
        #expect(edited.io.enterCount == 1)
        #expect(edited.bus.info("worker")?.needsOwnerEnter == false)

        // 2. Completion workflow: type prefix, Enter accepts completion (adds no new text before second Enter),
        //    or Tab invalidates exact text, then final Enter submits full completion text.
        let completed = Self.makeRig(cols: fx.cols, rows: fx.rows)
        completed.io.showBytes(fx.before)
        completed.bus.setState("worker", .running)
        completed.bus.noteOwnerInput("worker", bytes: Array("/stat".utf8)[...])
        completed.bus.noteOwnerInput("worker", bytes: [0x09][...]) // Tab invalidates exact string
        completed.bus.noteOwnerInput("worker", bytes: [0x0D][...]) // Enter accepts completion
        completed.bus.noteOwnerInput("worker", bytes: [0x0D][...]) // Second Enter submits (no new text)
        try completed.hook("UserPromptSubmit", prompt: "/status")
        try completed.hook("Stop")
        completed.step(4)
        completed.bus.tick()
        _ = try completed.send(fx.payload)
        completed.io.showBytes(fx.after)
        completed.fire()
        for _ in 0..<5 {
            completed.step(1)
            completed.bus.tick()
        }
        #expect(completed.io.enterCount == 1)
        #expect(completed.bus.info("worker")?.needsOwnerEnter == false)
    }

    @Test func duplicateEqualTextSubmitsHoldUntilSecondHookAndWhitespaceDiffDoesNotCollide() throws {
        let fx = try Self.loadCappedCase()

        // Case A (P1): owner submits "same", then types another "same" + completion Enter before hook 1 arrives.
        let dup = Self.makeRig(cols: fx.cols, rows: fx.rows)
        dup.io.showBytes(fx.before)
        dup.bus.setState("worker", .running)
        dup.bus.noteOwnerInput("worker", bytes: Array("same".utf8)[...])
        dup.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        dup.bus.noteOwnerInput("worker", bytes: Array("same".utf8)[...])
        dup.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try dup.hook("UserPromptSubmit", prompt: "same")
        try dup.hook("Stop")
        dup.step(4)
        dup.bus.tick()
        _ = try dup.send(fx.payload)
        dup.io.showBytes(fx.after)
        dup.fire()
        for _ in 0..<5 { dup.step(1); dup.bus.tick() }
        #expect(dup.io.enterCount == 0, "first 'same' hook cleared pending duplicate 'same' draft")
        #expect(dup.bus.info("worker")?.needsOwnerEnter == true)

        // Case B: when both 'same' hooks arrive, capped delivery succeeds cleanly.
        let both = Self.makeRig(cols: fx.cols, rows: fx.rows)
        both.io.showBytes(fx.before)
        both.bus.setState("worker", .running)
        both.bus.noteOwnerInput("worker", bytes: Array("same".utf8)[...])
        both.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        both.bus.noteOwnerInput("worker", bytes: Array("same".utf8)[...])
        both.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try both.hook("UserPromptSubmit", prompt: "same")
        try both.hook("UserPromptSubmit", prompt: "same")
        try both.hook("Stop")
        both.step(4)
        both.bus.tick()
        _ = try both.send(fx.payload)
        both.io.showBytes(fx.after)
        both.fire()
        for _ in 0..<5 { both.step(1); both.bus.tick() }
        #expect(both.io.enterCount == 1)
        #expect(both.bus.info("worker")?.needsOwnerEnter == false)

        // Case C: interior whitespace differences ("a b" vs "ab") must not collide.
        let space = Self.makeRig(cols: fx.cols, rows: fx.rows)
        space.io.showBytes(fx.before)
        space.bus.setState("worker", .running)
        space.bus.noteOwnerInput("worker", bytes: Array("ab".utf8)[...])
        space.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try space.hook("UserPromptSubmit", prompt: "a b")
        try space.hook("Stop")
        space.step(4)
        space.bus.tick()
        _ = try space.send(fx.payload)
        space.io.showBytes(fx.after)
        space.fire()
        for _ in 0..<5 { space.step(1); space.bus.tick() }
        #expect(space.io.enterCount == 0, "'a b' hook must not clear observed 'ab' draft")
        #expect(space.bus.info("worker")?.needsOwnerEnter == true)
    }

    @Test func delayedEarlierHookAcrossCtrlCOrVisibleBusPasteDoesNotClearLaterDraft() throws {
        let fx = try Self.loadCappedCase()

        // Case A (P1): observed A + Enter -> Ctrl-C -> B + Tab + Enter -> delayed A hook must NOT clear B.
        let ctrlC = Self.makeRig(cols: fx.cols, rows: fx.rows)
        ctrlC.io.showBytes(fx.before)
        ctrlC.bus.setState("worker", .running)
        ctrlC.bus.noteOwnerInput("worker", bytes: Array("earlier A".utf8)[...])
        ctrlC.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        ctrlC.bus.noteOwnerInput("worker", bytes: [0x03][...]) // Ctrl-C empties composer, not harness queue
        ctrlC.bus.noteOwnerInput("worker", bytes: Array("later".utf8)[...])
        ctrlC.bus.noteOwnerInput("worker", bytes: [0x09][...]) // Tab makes B's text unknown
        ctrlC.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try ctrlC.hook("UserPromptSubmit", prompt: "earlier A")
        try ctrlC.hook("Stop")
        ctrlC.step(4)
        ctrlC.bus.tick()
        _ = try ctrlC.send(fx.payload)
        ctrlC.io.showBytes(fx.after)
        ctrlC.fire()
        for _ in 0..<5 { ctrlC.step(1); ctrlC.bus.tick() }
        #expect(ctrlC.io.enterCount == 0, "delayed earlier A across Ctrl-C cleared later Tab draft")
        #expect(ctrlC.bus.info("worker")?.needsOwnerEnter == true)

        // Case B (P1): observed A + Enter -> visible (!headHidden) short bus paste -> B + Tab + Enter -> delayed A hook.
        let vis = Self.makeRig(cols: fx.cols, rows: fx.rows)
        let rule = String(repeating: "─", count: fx.cols)
        let shortBefore = Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\(rule)\r\n❯\u{a0}\r\n\(rule)\r\n  Usage: 5h n/a\r\n".utf8)
        let shortAfter = Data("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\(rule)\r\n❯\u{a0}[from: probe] short ok\r\n\(rule)\r\n  Usage: 5h n/a\r\n".utf8)
        vis.io.showBytes(shortBefore)
        vis.bus.setState("worker", .running)
        vis.bus.noteOwnerInput("worker", bytes: Array("earlier A".utf8)[...])
        vis.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try vis.hook("Stop")
        vis.step(4)
        let visReply = try vis.send("short ok")
        #expect(visReply["delivered"] as? Bool == true)
        vis.io.showBytes(shortAfter)
        vis.fire()
        #expect(vis.io.enterCount == 1)
        vis.step(1)
        vis.io.showBytes(fx.before)
        vis.bus.noteOwnerInput("worker", bytes: Array("later".utf8)[...])
        vis.bus.noteOwnerInput("worker", bytes: [0x09][...])
        vis.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try vis.hook("UserPromptSubmit", prompt: "earlier A")
        try vis.hook("Stop")
        vis.step(4)
        vis.bus.tick()
        let cappedReply = try vis.send(fx.payload)
        #expect(cappedReply["delivered"] as? Bool == true)
        vis.io.showBytes(fx.after)
        vis.fire()
        for _ in 0..<5 { vis.step(1); vis.bus.tick() }
        #expect(vis.io.enterCount == 1, "delayed earlier A across visible bus paste cleared later Tab draft")
        #expect(vis.bus.info("worker")?.needsOwnerEnter == true)
    }

    @Test func earlierHookArrivingWhileTypingTabDraftRetiresSlotWithoutPermanentDebt() throws {
        let fx = try Self.loadCappedCase()
        let rig = Self.makeRig(cols: fx.cols, rows: fx.rows)
        rig.io.showBytes(fx.before)
        rig.bus.setState("worker", .running)

        // Submit A; begin editing B with Tab; A's hook arrives during that typing; submit B; B's hook arrives.
        rig.bus.noteOwnerInput("worker", bytes: Array("first prompt".utf8)[...])
        rig.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        rig.bus.noteOwnerInput("worker", bytes: Array("second".utf8)[...])
        rig.bus.noteOwnerInput("worker", bytes: [0x09][...]) // Tab makes B unknown
        try rig.hook("UserPromptSubmit", prompt: "first prompt")
        rig.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try rig.hook("UserPromptSubmit", prompt: "second completed")
        try rig.hook("Stop")
        rig.step(4)
        rig.bus.tick()

        _ = try rig.send(fx.payload)
        rig.io.showBytes(fx.after)
        rig.fire()
        for _ in 0..<5 { rig.step(1); rig.bus.tick() }
        #expect(rig.io.enterCount == 1, "earlier hook during typing left permanent ordinal debt")
        #expect(rig.bus.info("worker")?.needsOwnerEnter == false)
    }

    @Test func sessionStartRetiresDeadSessionDebtAndAmbiguousUnhookedEnterFailsClosed() throws {
        let fx = try Self.loadCappedCase()

        // Part A (P2): SessionStart retires unhooked submit slots from the ended session.
        let reset = Self.makeRig(cols: fx.cols, rows: fx.rows)
        reset.io.showBytes(fx.before)
        reset.bus.noteOwnerInput("worker", bytes: Array("/cle".utf8)[...])
        reset.bus.noteOwnerInput("worker", bytes: [0x09][...])
        reset.bus.noteOwnerInput("worker", bytes: [0x0D][...]) // swallowed/local command without hook
        try reset.hook("SessionStart")
        reset.bus.noteOwnerInput("worker", bytes: Array("new".utf8)[...])
        reset.bus.noteOwnerInput("worker", bytes: [0x09][...])
        reset.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try reset.hook("UserPromptSubmit", prompt: "new task")
        try reset.hook("Stop")
        reset.step(4)
        reset.bus.tick()
        _ = try reset.send(fx.payload)
        reset.io.showBytes(fx.after)
        reset.fire()
        for _ in 0..<5 { reset.step(1); reset.bus.tick() }
        #expect(reset.io.enterCount == 1, "SessionStart left stale ordinal debt from previous session")
        #expect(reset.bus.info("worker")?.needsOwnerEnter == false)

        // Part B: fail-closed when two submits cannot be disambiguated ("fi" + completion Enter + "x" + Enter).
        let failClosed = Self.makeRig(cols: fx.cols, rows: fx.rows)
        failClosed.io.showBytes(fx.before)
        failClosed.bus.setState("worker", .running)
        failClosed.bus.noteOwnerInput("worker", bytes: Array("fi".utf8)[...])
        failClosed.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        failClosed.bus.noteOwnerInput("worker", bytes: Array("x".utf8)[...])
        failClosed.bus.noteOwnerInput("worker", bytes: [0x0D][...])
        try failClosed.hook("UserPromptSubmit", prompt: "file.txt x")
        try failClosed.hook("Stop")
        failClosed.step(4)
        failClosed.bus.tick()
        _ = try failClosed.send(fx.payload)
        failClosed.io.showBytes(fx.after)
        failClosed.fire()
        for _ in 0..<5 { failClosed.step(1); failClosed.bus.tick() }
        #expect(failClosed.io.enterCount == 0)
        #expect(failClosed.bus.info("worker")?.needsOwnerEnter == true)
    }
}

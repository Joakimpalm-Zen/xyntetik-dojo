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
}

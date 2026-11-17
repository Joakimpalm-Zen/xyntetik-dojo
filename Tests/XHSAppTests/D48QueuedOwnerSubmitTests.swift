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
    }
}

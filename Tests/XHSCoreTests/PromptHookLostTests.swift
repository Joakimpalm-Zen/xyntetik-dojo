import Foundation
import Testing
@testable import XHSCore

/// D35.1: a relayed message answered a permission prompt when the prompt's hook was lost. The pane was then
/// `running`, or `idle` after 15 still seconds, and the bus typed the message and its Enter into the dialog.
/// The bus now types, and presses Enter, only into a composer it can see.
@MainActor
@Suite struct PromptHookLostTests {
    @MainActor final class Rig {
        let bus = Bus()
        let io = MockIO()
        var pending: [() -> Void] = []
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var target = ""
        var sender = ""
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hook-lost-\(UUID().uuidString)")

        init(kind: HarnessKind = .claude, submitDelay: TimeInterval = 0) {
            bus.submitDelay = submitDelay
            bus.schedule = { [unowned self] _, work in self.pending.append(work) }
            bus.now = { [unowned self] in self.clock }
            bus.record = BusRecord(directory: folder)
            target = bus.add(name: "worker", kind: kind, io: io)
            sender = bus.add(name: "fable", kind: .claude, io: MockIO())
            hook("SessionStart")
        }

        func hook(_ event: String) {
            _ = bus.handle(path: "/hook", token: target, body: body(["hook_event_name": event]))
        }

        @discardableResult
        func send(_ text: String) -> [String: Any] {
            json(bus.handle(path: "/send", token: sender, body: body(["pane": "worker", "text": text])).body)
        }

        func fire() {
            clock += 0.15
            let work = pending
            pending = []
            for w in work { w() }
        }

        func wait(_ seconds: Int) {
            for _ in 0..<seconds { clock += 1; bus.tick() }
        }

        var enters: Int { io.written.filter { $0 == Delivery.enter }.count }

        /// The record's lines with this `op`.
        func recorded(_ op: String) -> [[String: Any]] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.flatMap { url in
                ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> [String: Any]? in
                    guard let fields = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          fields["op"] as? String == op else { return nil }
                    return fields
                }
            }
        }
    }

    private static let claudeComposer = ComposerShownTests.claude("❯\u{a0}")
    private static let codexComposer = ComposerShownTests.codex("› Ask Codex to do anything")

    @Test func aDialogWhoseHookWasLostIsNotTypedInto() {
        for (kind, dialog, composer) in [(HarnessKind.claude, ComposerShownTests.claudePermission(cursorOn: 1), Self.claudeComposer),
                                         (.codex, ComposerShownTests.codexApproval(cursorOn: 1), Self.codexComposer)] {
            let rig = Rig(kind: kind)
            rig.hook("UserPromptSubmit")
            // the harness asks for permission and its hook never arrives: the bus still thinks it is running
            rig.io.screen = dialog
            let reply = rig.send("status?")
            #expect(rig.bus.info("worker")?.state == .running, "\(kind)")
            #expect(reply["delivered"] as? Bool == false, "\(kind)")
            #expect((reply["note"] as? String)?.contains("no composer") == true, "\(kind)")
            #expect(rig.io.written.isEmpty, "\(kind): nothing may be typed into the dialog")
            #expect(rig.bus.info("worker")?.noComposer == true, "\(kind): the header says why it waits")
            // 15 still seconds make the pane idle; the dialog is still there
            rig.wait(20)
            #expect(rig.bus.info("worker")?.state == .idle, "\(kind)")
            #expect(rig.io.written.isEmpty, "\(kind): nor after the still-screen rule")
            #expect(rig.recorded("hold").count == 1, "\(kind): the record has the hold once, not once a second")
            // the owner answers the dialog; the composer is back and the message goes out, whole
            rig.io.screen = composer
            rig.wait(1)
            #expect(rig.io.typed == "[from: fable] status?\r", "\(kind)")
            #expect(rig.bus.info("worker")?.noComposer == false, "\(kind)")
            #expect(rig.bus.info("worker")?.queued == 0, "\(kind)")
        }
    }

    @Test func aDialogThatOpensBetweenThePasteAndItsEnterHoldsTheEnter() {
        let rig = Rig(submitDelay: 0.15)
        rig.io.screen = Self.claudeComposer
        rig.send("status?")
        #expect(rig.io.typed == "[from: fable] status?")
        // a dialog opens with no hook before the Enter comes due
        rig.io.screen = ComposerShownTests.claudeQuestion(cursorOn: 5)
        rig.fire()
        #expect(rig.enters == 0, "the Enter would have chosen for the owner")
        #expect(rig.recorded("enter").last?["outcome"] as? String == "owed")
        #expect(rig.recorded("enter").last?["why"] as? String == "no composer on the screen")
        rig.wait(5)
        #expect(rig.enters == 0)
        // the dialog is answered: the text is still in the composer and gets its Enter
        rig.io.screen = ComposerShownTests.claude("❯ [from: fable] status?")
        rig.wait(1)
        #expect(rig.enters == 1)
        #expect(rig.recorded("enter").last?["outcome"] as? String == "sent")
    }

    @Test func aRunningPaneThatShowsItsComposerIsTypedIntoAtOnce() {
        // PR #12's rule stays: a busy harness keeps the input in its own queue.
        for (kind, composer) in [(HarnessKind.claude, Self.claudeComposer), (.codex, Self.codexComposer)] {
            let rig = Rig(kind: kind)
            rig.hook("UserPromptSubmit")
            rig.io.screen = composer
            let reply = rig.send("status?")
            #expect(reply["delivered"] as? Bool == true, "\(kind)")
            #expect(rig.io.typed == "[from: fable] status?\r", "\(kind)")
            #expect(rig.recorded("hold").isEmpty, "\(kind)")
        }
    }

    @Test func theWholeQueueStillGoesOutAsOneInput() {
        let rig = Rig()
        rig.hook("UserPromptSubmit")
        rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 2)
        rig.send("one")
        rig.send("two")
        #expect(rig.bus.info("worker")?.queued == 2)
        rig.io.screen = Self.claudeComposer
        rig.wait(1)
        #expect(rig.io.typed == "[from: fable] one [from: fable] two\r")
    }

    @Test func aPaneWithNoComposerRuleIsTypedIntoAsBefore() {
        // pi has no permission prompts and a shell has no dialogs: whatever the screen shows
        for kind in [HarnessKind.pi, .shell] {
            let rig = Rig(kind: kind)
            rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 1)
            let reply = rig.send("status?")
            #expect(reply["delivered"] as? Bool == true, "\(kind)")
            #expect(rig.io.typed == "[from: fable] status?\r", "\(kind)")
        }
    }

    @Test func aPromptKnownFromItsHookIsHeldAsBefore() {
        let rig = Rig()
        rig.hook("UserPromptSubmit")
        rig.hook("PermissionRequest")
        rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 1)
        let reply = rig.send("status?")
        #expect(reply["delivered"] as? Bool == false)
        #expect((reply["note"] as? String)?.contains("at a prompt") == true)
        #expect(rig.io.written.isEmpty)
        rig.wait(60)
        #expect(rig.bus.info("worker")?.state == .prompt)
        #expect(rig.io.written.isEmpty)
    }
}

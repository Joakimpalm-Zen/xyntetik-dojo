import Foundation
import Testing
@testable import XHSCore

/// The reviewer's fourth read of #102 gave five traces from the code, with no tests run. These are those
/// traces as tests, written here from its report: the screens are the report's, word for word.
@MainActor @Suite struct D102314ReviewTests {
    typealias Rig = PromptHookLostTests.Rig
    static let bar = "────────"

    static func claude(_ composer: String, _ under: String...) -> String {
        ([bar, composer, bar] + under).joined(separator: "\n")
    }

    /// 1. A menu adds its selected entry under a composer that stays. The new row is a whole part of an old
    /// row, so both rows matched that one old row.
    @Test func aRowAddedUnderTheComposerHoldsTheEnterThoughItIsAPartOfAnOldRow() {
        let rig = Rig(kind: .codex, submitDelay: 0.15)
        rig.io.screen = "\n› Ask Codex to do anything\n\n  GPT-6.1-Sol · Full Access"
        rig.send("status?")
        rig.io.screen = "\n› [from: fable] status?\n\n  GPT-6.1-Sol · Full Access\n  Full Access"
        rig.fire()
        #expect(rig.enters == 0, "a row more than before is a new row")
        rig.wait(30)
        #expect(rig.enters == 0, "and an added row never becomes the footer to compare against")
        #expect(rig.bus.info("worker")?.noComposer == true)
    }

    /// 2. The owner's Enter accepts a completion that edits the pasted text. No hook fires. The composer is
    /// free and holds other text: that is a draft, not a submission.
    @Test func aCompletionThatEditsThePastedTextLeavesADraftNotASubmission() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("read @sr")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = Self.claude("❯ [from: fable] read @src/", "  status")
        rig.fire()
        rig.wait(5)
        #expect(rig.enters == 0, "the text is no longer the bus's to send")
        #expect(rig.bus.info("worker")?.draft == true, "it is the owner's draft now")
        rig.send("second")
        rig.wait(10)
        #expect(!rig.io.typed.contains("second"), "nothing is typed onto the unsent draft")
        #expect(rig.bus.info("worker")?.queued == 1)
    }

    /// 3. A second background shell starts in the paste delay: "1 shell" becomes "2 shells". The Enter was
    /// owed for good. Main sends it.
    @Test func aStatusWordThatChangesInThePasteDelayDoesNotHoldTheEnterForGood() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  ⏵⏵ bypass permissions on · 1 shell")
        rig.send("status?")
        rig.io.screen = Self.claude("❯ [from: fable] status?", "  ⏵⏵ bypass permissions on · 2 shells")
        rig.fire()
        rig.wait(10)
        #expect(rig.enters == 1)
        #expect(rig.bus.info("worker")?.noComposer == false)
        rig.send("second")
        rig.io.screen = Self.claude("❯", "  ⏵⏵ bypass permissions on · 2 shells")
        rig.wait(5)
        #expect(rig.io.typed.contains("second"), "later messages are not blocked")
    }

    /// 5. Prompt A's submit hook comes late, after the bus pasted message B, and the owner's Enter in that
    /// moment answered a dialog. Neither sent B.
    @Test func aLateHookOfAnEarlierPromptWithAnOwnersEnterOnADialogDoesNotCountAsThisPasteSent() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("message B")
        rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 1)
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)          // answers the dialog
        rig.clock += 0.01
        rig.hook("UserPromptSubmit", ["prompt": "prompt A, sent before the paste"])
        rig.fire()
        rig.io.screen = Self.claude("❯ [from: fable] message B", "  status")
        rig.wait(5)
        #expect(rig.enters == 1, "B is still in the composer and gets its Enter")
        #expect(rig.recorded("enter").last?["outcome"] as? String == "sent")
    }
}

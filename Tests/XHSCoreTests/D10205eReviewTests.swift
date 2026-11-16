import Foundation
import Testing
@testable import XHSCore

/// The reviewer's fifth read of #102 gave two traces from the code, both in the evidence for what the
/// owner's Enter did. These are those traces as tests, written here from its report with its screens.
@MainActor @Suite struct D10205eReviewTests {
    typealias Rig = PromptHookLostTests.Rig
    static func claude(_ composer: String, _ under: String...) -> String {
        ([D102314ReviewTests.bar, composer, D102314ReviewTests.bar] + under).joined(separator: "\n")
    }

    /// 1. An earlier prompt with the very same text has a late hook. It arrives after the bus pasted that
    /// text again and BEFORE the owner's Enter, which accepts a completion that edits the text. The hook
    /// proves nothing about an Enter that came after it, and the screen shows a draft.
    @Test func anEarlierHookWithTheSameTextDoesNotProveALaterEnter() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("read @sr")
        rig.clock += 0.02
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] read @sr"])   // prompt A's, late
        rig.clock += 0.03
        rig.bus.noteOwnerInput("worker", .submit)                             // accepts a completion
        rig.io.screen = Self.claude("❯ [from: fable] read @src/", "  status")
        rig.fire()
        rig.wait(5)
        #expect(rig.enters == 0)
        #expect(rig.bus.info("worker")?.draft == true, "the edited text is the owner's draft")
        rig.send("second")
        rig.wait(10)
        #expect(!rig.io.typed.contains("second"), "nothing is typed onto the unsent draft")
    }

    /// The same early hook, and the owner's Enter leaves the pasted text as it was: the bus's Enter is not
    /// lost to that hook.
    @Test func anEarlierHookWithTheSameTextDoesNotLoseTheBussEnter() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("read @sr")
        rig.clock += 0.02
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] read @sr"])
        rig.clock += 0.03
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = Self.claude("❯ [from: fable] read @sr", "  status")
        rig.fire()
        rig.wait(5)
        #expect(rig.enters == 1, "the text is still there and gets its Enter")
    }

    /// 2. The owner really submits the pasted text while the harness works. The composer comes back free,
    /// with the harness's own row for a queued message. That is a composer the text has left, not a draft:
    /// no hold is set, and later messages go out.
    @Test func theHarnesssRowForAQueuedMessageIsNotADraft() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("status?")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = Self.claude("❯ Press up to edit queued messages", "  status")
        rig.fire()
        #expect(rig.enters == 0)
        #expect(rig.recorded("enter").last?["outcome"] as? String == "dropped")
        #expect(rig.bus.info("worker")?.draft == false, "no key of the owner's added text")
        rig.clock += 0.5
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] status?"])     // the matching hook, after the callback
        rig.send("second")
        rig.wait(5)
        #expect(rig.io.typed.contains("second"), "later messages are not held")
        #expect(rig.bus.info("worker")?.queued == 0)
    }

    /// The confirming read's trace. The bus's Enter is owed; the owner really sends the text; the matching
    /// hook comes after that Enter; and the free composer then shows the harness's own suggestion. The
    /// suggestion is not the owner's draft: it does not begin with the tag the bus puts before its text.
    @Test func theHarnesssOwnSuggestionAfterAProvenSubmissionIsNotADraft() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("status?")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .other)                              // a Left key: the Enter is owed
        rig.fire()
        #expect(rig.recorded("enter").last?["outcome"] as? String == "owed")
        rig.clock += 1
        rig.bus.noteOwnerInput("worker", .submit)                             // the owner sends the text
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] status?"])     // and the hook says so
        rig.io.screen = Self.claude("❯ Try \"fix the failing test\"", "  status")
        rig.wait(1)
        #expect(rig.enters == 0)
        #expect(rig.recorded("enter").last?["outcome"] as? String == "dropped")
        #expect(rig.bus.info("worker")?.draft == false, "the suggestion is the harness's, and the hook proved the submission")
        rig.send("second")
        rig.wait(5)
        #expect(rig.io.typed.contains("second"), "later messages are not held")
    }

    /// The same suggestion with no hook: nothing shows that the text was sent, so the hold is set, as before.
    @Test func otherTextWithNoHookIsStillTheOwnersDraft() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("status?")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = Self.claude("❯ half a thought of the owner's", "  status")
        rig.fire()
        #expect(rig.enters == 0)
        #expect(rig.bus.info("worker")?.draft == true)
    }

    /// The fifth read's completion edit, now with a matching hook AFTER the owner's Enter: the text in the
    /// composer begins with the bus's tag, so it is the paste, edited, and the owner's draft whatever the
    /// hook said.
    @Test func thePastedTextEditedIsADraftEvenWithAMatchingHookAfterTheEnter() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("read @sr")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)                             // accepts a completion
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] read @sr"])    // an identical earlier prompt's, late
        rig.io.screen = Self.claude("❯ [from: fable] read @src/", "  status")
        rig.fire()
        rig.wait(5)
        #expect(rig.enters == 0)
        #expect(rig.bus.info("worker")?.draft == true, "the edited paste is the owner's draft")
        rig.send("second")
        rig.wait(10)
        #expect(!rig.io.typed.contains("second"))
    }

    /// The second confirming read's trace, five things at once. An earlier prompt with the very same text
    /// has a hook that comes seconds late. The bus pastes that text again; the owner takes its first
    /// character away with keys that add no text, so the Enter is owed; a dialog opens with no hook and
    /// the owner answers it with Enter; and the old hook arrives after that Enter. What is in the composer
    /// is the paste, edited: it shares a long run of characters with what was pasted, tag or no tag.
    @Test func aPartlyEditedPasteIsADraftWhateverALateHookSays() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯", "  status")
        rig.send("status?")
        rig.clock += 0.05
        for _ in 0..<3 { rig.bus.noteOwnerInput("worker", .other) }          // Home, forward Delete, End
        rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 1)
        rig.fire()
        #expect(rig.recorded("enter").last?["outcome"] as? String == "owed")
        rig.clock += 1
        rig.bus.noteOwnerInput("worker", .submit)                             // answers the dialog
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] status?"])     // the earlier prompt's, late
        rig.io.screen = Self.claude("❯ from: fable] status?", "  status")
        rig.wait(5)
        #expect(rig.enters == 0)
        #expect(rig.bus.info("worker")?.draft == true, "what is left of the paste is the owner's draft")
        rig.send("second")
        rig.wait(10)
        #expect(!rig.io.typed.contains("second"), "nothing is typed onto it")
    }
}

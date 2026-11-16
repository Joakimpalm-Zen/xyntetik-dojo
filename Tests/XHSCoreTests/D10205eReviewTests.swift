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
}

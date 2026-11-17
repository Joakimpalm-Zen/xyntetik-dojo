import Foundation
import Testing
@testable import XHSCore

@MainActor @Suite struct D102043ReviewTests {
    typealias Rig = PromptHookLostTests.Rig
    @Test func extendingAnOldFooterWithADialogQuestionDoesNotAuthorizeEnter() {
        let r=Rig(kind:.claude,submitDelay:0.15)
        let old="  ⏵⏵ bypass permissions on"
        r.io.screen=ComposerShownTests.claude("❯",foot:old)
        r.io.alternate=true;r.hook("Stop")
        r.send("status?")
        r.io.screen=ComposerShownTests.claude("❯ [from: fable] status?",foot:old+" · Allow this action?")
        r.io.cursorLine=r.io.screen.components(separatedBy:"\n").count-1
        r.fire()
        #expect(r.enters == 0)
    }
    @Test func aStatusCounterCrossingADigitBoundaryStillGetsItsEnter() {
        let r=Rig(kind:.claude,submitDelay:0.15)
        r.io.screen=ComposerShownTests.claude("❯",foot:"  Context: 9% used")
        r.send("status?")
        r.io.screen=ComposerShownTests.claude("❯ [from: fable] status?",foot:"  Context: 10% used")
        r.fire();r.wait(30)
        #expect(r.enters == 1)
        #expect(r.bus.info("worker")?.noComposer == false)
    }
    @Test func enterThatOnlyAcceptsACompletionDoesNotSilentlyLoseSubmission() {
        let r=Rig(kind:.claude,submitDelay:0.15)
        // the composer, with the footer it keeps (D39: the mock's own had another, and the Enter was owed for it)
        r.io.screen=ComposerShownTests.claude("❯")
        r.send("status?")
        r.clock += 0.05
        r.bus.noteOwnerInput("worker",.submit)
        // Enter accepted a completion. No submit hook and no cleared row.
        r.io.screen=ComposerShownTests.claude("❯ [from: fable] status?")
        r.fire();r.wait(5)
        // the composer still holds the bus's text, which is the bus's to send: its Enter goes out once the owner
        // is quiet (D39: this took either outcome, though the bus does one)
        #expect(r.enters == 1, "the still-unsent message gets its Enter")
        #expect(r.bus.info("worker")?.noComposer == false)
        #expect(r.bus.info("worker")?.queued == 0)
        r.send("second")
        #expect(!r.io.typed.contains("second"),
                "the completion left an unsent draft in the composer")
    }
    @Test func aDelayedStopWhileAnEditorShowsDoesNotLearnItsBuffer() {
        let r=Rig(kind:.codex,submitDelay:0.15)
        r.io.alternate=true;r.hook("Stop")
        r.io.alternate=false;r.io.screen="ordinary editor contents"
        r.hook("Stop") // a delayed hook from the previous turn
        r.io.alternate=true
        r.io.screen=ComposerShownTests.codex("› Ask Codex to do anything")
        r.send("status?");r.wait(30)
        #expect(r.io.typed.contains("status?"))
        #expect(r.bus.info("worker")?.queued == 0)
    }
    @Test func punctuationDoesNotHideARealKeyHint() {
        #expect(Composer.hasKeyHint("(enter select)"))
        let screen=ComposerShownTests.claude("❯ Yes, allow",foot:"  (enter select)")
        #expect(Composer.look(kind:.claude,lines:screen.components(separatedBy:"\n"),cursorLine:nil) == nil)
    }
    @Test func aLongerProjectNameDoesNotBecomeADialogHint() {
        let r=Rig(kind:.codex,submitDelay:0.15)
        let foot=ComposerShownTests.codexFoot.replacingOccurrences(of:"~/AI_projects/origin",with:"~/please press enter")
        r.io.screen=ComposerShownTests.codex("› Ask Codex to do anything",foot:foot)
        #expect(r.send("status?")["delivered"] as? Bool == true)
        #expect(!r.io.written.isEmpty)
    }
}

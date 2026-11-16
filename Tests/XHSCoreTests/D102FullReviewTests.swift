import Foundation
import Testing
@testable import XHSCore

/// The reviewer's tests from the second read of #102, as written. One is marked as a known issue, which is
/// said at it; nothing else is changed.
@MainActor @Suite struct D102FullReviewTests {
    /// The residue of D35.1, kept as the reviewer wrote it and marked as a known issue: a dialog whose own
    /// shape reads as a composer and a footer (the mark in the first column between two ruled lines, plain
    /// rows set in under it, no key hint), up before the bus has typed anything, with no hook reporting it.
    /// Nothing on the screen tells it from a composer, and there is no look from before to hold it against.
    /// The cursor would (it is on "No, quit"), once a real pane has shown where each harness keeps it.
    @Test func aPlainIndentedDialogIsNotAStatusFooter() {
        let rig=PromptHookLostTests.Rig(kind:.claude,submitDelay:0.15)
        rig.io.screen="Trust this folder?\n────────────────────\n❯ Yes, allow\n────────────────────\n  No, quit"
        rig.io.cursorLine=4
        withKnownIssue("a dialog drawn like a composer with a footer, and no look from before it") {
            #expect(rig.send("status?")["delivered"] as? Bool == false)
            #expect(rig.io.written.isEmpty)
        }
        // with the cursor's line as evidence it is held
        let told=PromptHookLostTests.Rig(kind:.claude,submitDelay:0.15)
        told.bus.cursorEvidence=[.claude]
        told.io.screen=rig.io.screen
        told.io.cursorLine=4
        #expect(told.send("status?")["delivered"] as? Bool == false)
        #expect(told.io.written.isEmpty)
    }

    @Test func aDialogBelowTheActualPastedComposerStillHoldsEnter() {
        for kind in [HarnessKind.claude,.codex] {
            let rig=PromptHookLostTests.Rig(kind:kind,submitDelay:0.15)
            rig.send("status?")
            rig.io.screen = kind == .claude
                ? ComposerShownTests.claude("❯ [from: fable] status?",foot:"  Allow this action?\n  Yes / No")
                : ComposerShownTests.codex("› [from: fable] status?",foot:"  Allow this action?\n  Yes / No")
            rig.io.cursorLine=rig.io.screen.components(separatedBy:"\n").count-1
            rig.fire()
            #expect(rig.enters == 0,"a dialog owns input, although the old composer remains visible")
        }
    }

    @Test func anOldPlaceholderIsNotEvidenceOfThisPasteArriving() {
        for kind in [HarnessKind.claude,.codex] {
            let rig=PromptHookLostTests.Rig(kind:kind,submitDelay:0.15)
            rig.io.screen = kind == .claude
                ? ComposerShownTests.claude("❯ [Pasted text #7]")
                : ComposerShownTests.codex("› [Pasted Content 2000 chars]")
            rig.send("new message not drawn yet")
            rig.fire()
            #expect(rig.enters == 0,"the unchanged stand-in was already on screen before this paste")
        }
    }

    @Test func aProjectNameInTheStatusIsNotADialogHint() {
        let rig=PromptHookLostTests.Rig(kind:.codex,submitDelay:0.15)
        let status=ComposerShownTests.codexFoot.replacingOccurrences(of:"~/AI_projects/origin",with:"~/press enter")
        rig.io.screen=ComposerShownTests.codex("› Ask Codex to do anything",foot:status)
        #expect(rig.send("status?")["delivered"] as? Bool == true)
        #expect(!rig.io.written.isEmpty)
    }

    @Test func ownerSubmitOrClearBeforeTheDelayedEnterDoesNotWedgeTheNextMessage() {
        for key in [Bus.OwnerKey.submit,.clear] {
            let rig=PromptHookLostTests.Rig(kind:.claude,submitDelay:0.15)
            rig.send("first")
            rig.clock += 0.05
            rig.bus.noteOwnerInput("worker",key)
            rig.io.screen=ComposerShownTests.claude("❯")
            rig.fire()
            rig.send("second")
            rig.wait(30)
            #expect(rig.io.typed.contains("second"),"the old paste was submitted or cleared by the owner")
            #expect(rig.bus.info("worker")?.queued == 0)
        }
    }

    @Test func literalStandInTextInAMessageDoesNotMatchADifferentMessage() {
        let rows=["[from: fable] here is [Pasted Content 2000 chars]"]
        #expect(!Composer.holds("[from: fable] different",rows:rows,standIn:"[Pasted Content "))
        #expect(Composer.holds(rows[0],rows:rows,standIn:"[Pasted Content "))
    }
}

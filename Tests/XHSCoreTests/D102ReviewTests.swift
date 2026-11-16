import Foundation
import Testing
@testable import XHSCore

@MainActor
@Suite struct D102ReviewTests {
    @Test func claudeTranscriptQuoteAboveNumberedDialogMustNotAuthorizeEnter() {
        let rig = PromptHookLostTests.Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = ComposerShownTests.claude("❯")
        rig.send("status?")
        let transcript = "──────────────────────────────\n> a quoted prompt from earlier output\n"
        rig.io.screen = transcript + ComposerShownTests.claudePermission(cursorOn: 1)
        #expect(Composer.shown(kind: .claude, screen: rig.io.screen, afterPaste: true) == false)
        rig.fire()
        #expect(rig.enters == 0, "The numbered permission dialog is active")
    }

    @Test func claudeTranscriptAboveCompactNumberedDialogMustNotAuthorizePaste() {
        let rig = PromptHookLostTests.Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = "──────────────────────────────\n> a quoted prompt from output\n\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel"
        let reply=rig.send("status?")
        #expect(reply["delivered"] as? Bool == false)
        #expect(rig.io.written.isEmpty)
    }

    @Test func codexDoesNotCountArbitraryDialogLinesAsStatusLines() {
        let rig = PromptHookLostTests.Rig(kind: .codex, submitDelay: 0.15)
        rig.io.screen = "› remove the build folder\n\nWould you like to run the following command?\n$ rm -rf build\n1. Yes, proceed\n2. No\nPress enter to confirm"
        let reply=rig.send("status?")
        #expect(reply["delivered"] as? Bool == false)
        #expect(rig.io.written.isEmpty)
    }

    @Test func wrappedCodexNumberedChoiceDoesNotAuthorizePaste() {
        let rig=PromptHookLostTests.Rig(kind: .codex,submitDelay:0.15)
        // Five-column physical rows: the space after the dot is trimmed from its row.
        rig.io.screen="Allow\nthis?\n\n› 1.\nYes\n  2.\nNo\n\nEnter\nto\nallow"
        #expect(Composer.shown(kind: .codex,screen:rig.io.screen) == false)
        rig.send("status?")
        #expect(rig.io.written.isEmpty)
    }

    @Test func codexPastedQuoteIsNotASelectedDialogChoice() {
        let rig=PromptHookLostTests.Rig(kind: .codex, submitDelay: 0.15)
        rig.io.bracketedPasteEnabled=true
        rig.io.screen=ComposerShownTests.codex("› Ask Codex to do anything")
        rig.send("Please explain this choice:\n› 1. Yes")
        rig.io.screen=ComposerShownTests.codex("› [from: fable] Please explain this choice:\n  › 1. Yes")
        #expect(Composer.shown(kind: .codex, screen: rig.io.screen, afterPaste: true) == true)
        rig.fire()
        rig.wait(20)
        #expect(rig.enters == 1, "A two-line paste into a real composer must still be submitted")
    }

    @Test func owedEnterDoesNotTrustAnUnmarkedDialogBelowOldPrompt() {
        let rig=PromptHookLostTests.Rig(kind: .codex, submitDelay: 0.15)
        rig.io.screen=ComposerShownTests.codex("› Ask Codex to do anything")
        rig.send("status?")
        rig.io.screen=ComposerShownTests.codexApproval(cursorOn: 0)
        rig.fire()
        #expect(rig.enters == 0)
    }

    @Test func headerClearsAfterOwnerDischargesOwedEnter() {
        for key in [Bus.OwnerKey.submit, .clear, .text] {
            let rig=PromptHookLostTests.Rig(kind: .claude, submitDelay: 0.15)
            rig.io.screen=ComposerShownTests.claude("❯")
            rig.send("status?")
            rig.io.screen=ComposerShownTests.claudePermission(cursorOn: 1)
            rig.fire()
            #expect(rig.bus.info("worker")?.noComposer == true)
            rig.clock += 0.1
            rig.bus.noteOwnerInput("worker",key)
            rig.io.screen=ComposerShownTests.claude("❯")
            rig.wait(20)
            #expect(rig.bus.info("worker")?.queued == 0)
            #expect(rig.bus.info("worker")?.noComposer == false,"The header otherwise says Enter held forever, even after the Enter was dropped")
        }
    }

    @Test func nonNumberedClaudeDialogChoiceIsNotAComposer() {
        let screen="Approve this command?\n────────────────────\n❯ Yes\n  No\nEnter to select"
        #expect(Composer.shown(kind: .claude, screen: screen) == false)
    }

    @Test func screenContentStaysOutOfRepliesAndTheRecord() throws {
        let rig=PromptHookLostTests.Rig(kind: .claude)
        let marker="screen-only-sensitive-marker"
        rig.io.screen="private output: " + marker + "\nUnknown composer format"
        let reply=rig.send("status?")
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: reply), as: UTF8.self).contains(marker))
        rig.wait(20)
        #expect(rig.bus.info("worker")?.queued == 1)
        let holds=rig.recorded("hold")
        #expect(holds.count == 1)
        #expect(!String(decoding: try JSONSerialization.data(withJSONObject: holds), as: UTF8.self).contains(marker))
        rig.io.screen=ComposerShownTests.claude("❯")
        rig.wait(1)
        #expect(rig.io.typed == "[from: fable] status?\r")
    }

    @Test func terminalScreenUpdateBeforeQueuedWriteIsNotAtomic() {
        final class QueuedIO: PaneIO {
            var screen=ComposerShownTests.claude("❯")
            var written: [[UInt8]]=[]
            var awaiting: [[UInt8]]=[]
            var bracketedPasteEnabled=true
            func screenText() -> String { screen }
            func visibleText() -> String { screen }
            func write(_ bytes:[UInt8]) { awaiting.append(bytes) }
            func drainIntoDialog() {
                screen=ComposerShownTests.claudePermission(cursorOn:1)
                written += awaiting
                awaiting=[]
            }
        }
        let io=QueuedIO(), senderIO=MockIO(), bus=Bus()
        var pending:[()->Void]=[]
        bus.schedule={_,w in pending.append(w)}
        _=bus.add(name:"worker",kind:.claude,io:io)
        let sender=bus.add(name:"sender",kind:.claude,io:senderIO)
        bus.setState("worker",.idle)
        _=bus.handle(path:"send",token:sender,body:body(["pane":"worker","text":"status?"]))
        for w in pending { w() }
        io.drainIntoDialog()
        #expect(!io.written.contains(Delivery.enter),"The snapshot and DispatchIO write cannot guarantee the same harness UI is still active")
        _=senderIO
    }
}

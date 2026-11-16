import Foundation
import Testing
@testable import XHSCore

/// D38: the bus with an agy pane, as with Claude and Codex: typed into an idle composer, into agy's own queue
/// while it runs, held at a dialog or a question, and never onto the owner's unsent text. The screens are
/// agy 1.5.9's, read off a pty on 2026-11-16 (Tests/XHSAppTests/Fixtures has the bytes), cut to their foot.
@MainActor @Suite struct AgyDeliveryTests {
    typealias Rig = PromptHookLostTests.Rig

    static let rule = String(repeating: "─", count: 60)
    static let status = "Usage: 5h 90% left, resets at 13:00 · week 90% left | Ctx: 10k / 1000k | Model: Gemini 3.8 Flash (High) | Thinking: HIGH"
    static let idle = ["  The file /tmp/agy-dojo-pty-probe has been created.", "", rule, ">", rule, status].joined(separator: "\n")
    static let running = ["  Note 18: keep the sentences short.", "⣻  Generating...", rule, ">", rule, status].joined(separator: "\n")
    static let queued = ["⢿  Drafting the story", "▸ and then give me the first ten decimals of pi (alt+m to send immediately)",
                         rule, ">", rule, status].joined(separator: "\n")
    static let draft = [rule, "> half a thought", rule, status].joined(separator: "\n")
    static let dialog = ["● Ran (touch /tmp/agy-dojo-pty-probe) (ctrl+o to expand)", "", "Command", rule, "",
                         "Requesting permission for:", "   touch /tmp/agy-dojo-pty-probe", "", "Run this command?",
                         "> 1. Yes, run command",
                         "  2. Yes, and always allow in this conversation for commands that start with 'touch'",
                         "  3. Yes, and always allow for commands that start with 'touch' (Persist to settings.json)",
                         "  4. No, cancel", "", "  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command", status].joined(separator: "\n")
    static let question = ["? Which language would you like for the Hello World program?", "", "Question", rule, "",
                           "Question 1/1: Which language would you like for the Hello World program?", "",
                           "> 1. (Recommended) Python", "  2. Go", "  3. Rust", "  4. Write-in...", "",
                           "  ↑/↓ Navigate · enter Select · esc Skip", status].joined(separator: "\n")

    @Test func anIdleComposerIsTypedIntoAndSent() {
        let rig = Rig(kind: .agy)
        rig.io.screen = Self.idle
        #expect(rig.send("status?")["delivered"] as? Bool == true)
        #expect(rig.io.typed == "[from: fable] status?\r")
    }

    /// agy keeps its composer on the screen while it works and queues what comes in, above the composer.
    @Test func aRunningAgyTakesTheMessageIntoItsOwnQueue() {
        for screen in [Self.running, Self.queued] {
            let rig = Rig(kind: .agy)
            rig.hook("UserPromptSubmit")
            rig.io.screen = screen
            #expect(rig.send("status?")["delivered"] as? Bool == true)
            #expect(rig.io.typed == "[from: fable] status?\r")
        }
    }

    /// The status line put the pane at prompt: the message waits for the answer, then goes out.
    @Test func aPermissionDialogHoldsTheMessageUntilItIsAnswered() {
        let rig = Rig(kind: .agy)
        rig.hook("UserPromptSubmit")
        rig.hook("PermissionRequest")
        rig.io.screen = Self.dialog
        #expect(rig.send("status?")["delivered"] as? Bool == false)
        #expect(rig.bus.info("worker")?.state == .prompt)
        rig.wait(30)
        #expect(rig.io.written.isEmpty, "a prompt is never timed out")
        rig.hook("PostToolUse")
        rig.io.screen = Self.running
        rig.wait(1)
        #expect(rig.io.typed == "[from: fable] status?\r")
    }

    /// No report came (an agy without the status line's field, or a lost one): the screen holds it all the same.
    @Test func aDialogOrAQuestionWithNoReportIsStillNotTypedInto() {
        for screen in [Self.dialog, Self.question] {
            let rig = Rig(kind: .agy)
            rig.hook("UserPromptSubmit")
            rig.io.screen = screen
            #expect(rig.send("status?")["delivered"] as? Bool == false)
            #expect(rig.bus.info("worker")?.noComposer == true)
            rig.wait(20)
            #expect(rig.io.written.isEmpty)
            rig.io.screen = Self.idle
            rig.wait(1)
            #expect(rig.io.typed == "[from: fable] status?\r")
        }
    }

    /// What agy draws of a paste: a short one row by row, a long one as its stand-in. The Enter waits for it.
    @Test func aPasteGetsItsEnterOnceAgyShowsIt() {
        let rig = Rig(kind: .agy, submitDelay: 0.15)
        rig.send("status?")
        rig.fire()
        #expect(rig.enters == 1)
        rig.io.bracketedPasteEnabled = true
        rig.send("one\ntwo\nthree")
        rig.fire()
        #expect(rig.enters == 2)
        rig.send((1...20).map { "line \($0)" }.joined(separator: "\n"))
        rig.fire()
        #expect(rig.enters == 3)
    }

    /// The owner's unsent text in agy's composer holds the bus, until agy reports the prompt that carried it
    /// (its first model call of the turn, which `dojo hook agy` posts as UserPromptSubmit with the text) and
    /// the composer is empty.
    @Test func theOwnersTextIsNeverSent() {
        let rig = Rig(kind: .agy)
        rig.io.screen = Self.draft
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("report")
        rig.wait(30)
        #expect(rig.io.written.isEmpty)
        #expect(rig.bus.info("worker")?.draft == true)
        // the owner sends it
        rig.bus.noteOwnerInput("worker", .submit)
        rig.hook("UserPromptSubmit", ["prompt": "half a thought"])
        rig.io.screen = Self.running
        rig.wait(5)
        #expect(rig.io.typed == "[from: fable] report\r")
    }
}

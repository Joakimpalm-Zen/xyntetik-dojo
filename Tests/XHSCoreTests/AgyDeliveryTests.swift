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

    /// agy's mode in an empty composer (Auto, its own default, until the first prompt; the other modes from
    /// its binary): an empty composer, which ends a draft hold as an empty one does.
    static let modes = ["Auto mode: edits & safe commands auto-approved (shift+tab to cycle)",
                        "Accept-edits mode: file edits auto-approved (shift+tab to cycle)",
                        "Plan mode: research & plan only (shift+tab to cycle)",
                        "Best-of-N mode: fork into parallel arms and pick a winner (shift+tab to cycle)"]

    @Test func agysModeInAnEmptyComposerIsAnEmptyComposer() {
        for mode in Self.modes {
            let screen = [Self.rule, "> " + mode, Self.rule, Self.status].joined(separator: "\n")
            #expect(Composer.shownEmpty(kind: .agy, screen: screen), "\(mode)")
            // the owner's text after a mode sentence is a draft, after one space or two (the second read of #113:
            // the padding that marks a hint at Codex's right edge is no sign of an empty agy composer)
            for typed in [" and more", "  explain this", "   explain this"] {
                #expect(!Composer.shownEmpty(kind: .agy, screen: [Self.rule, "> " + mode + typed, Self.rule, Self.status].joined(separator: "\n")),
                        "\(mode)\(typed)")
            }
            let rig = Rig(kind: .agy)
            rig.io.screen = Self.draft
            rig.bus.noteOwnerInput("worker", .text)
            rig.send("report")
            rig.wait(10)
            #expect(rig.io.written.isEmpty)
            rig.io.screen = screen
            rig.wait(5)
            #expect(rig.io.typed == "[from: fable] report\r", "\(mode)")
        }
    }

    /// The owner's unsent draft begins with agy's mode sentence and two spaces: the bus holds, and types
    /// nothing onto it, however long the owner is quiet (the second read of #113, as it reproduced it).
    @Test func aDraftThatBeginsWithAModeSentenceIsHeld() {
        let draft = [Self.rule, "> " + Self.modes[0] + "  explain this", Self.rule, Self.status].joined(separator: "\n")
        let rig = Rig(kind: .agy)
        rig.io.screen = draft
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("report")
        rig.wait(30)
        #expect(rig.io.written.isEmpty)
        #expect(rig.bus.info("worker")?.draft == true)
        #expect(rig.bus.info("worker")?.queued == 1)
    }

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

    /// A message taller than agy's composer: agy shows its end under "↑ N more lines". The Enter goes out as
    /// it does for any paste agy shows (live on 2026-11-16 it stayed owed until the owner pressed it).
    @Test func aPasteTallerThanTheComposerGetsItsEnter() {
        let text = (1...12).map { "line \($0) of a relayed message long enough to fill more rows than the composer shows" }
            .joined(separator: "\n")
        let rig = Rig(kind: .agy, submitDelay: 0.15)
        rig.io.screen = Self.idle
        rig.io.bracketedPasteEnabled = true
        rig.send(text)
        let tail = Delivery.line(from: "fable", text: text).components(separatedBy: "\n").suffix(5).map { "  " + $0 }
        rig.io.screen = ([Self.rule, "> ↑ 7 more lines"] + tail + [Self.rule, Self.status]).joined(separator: "\n")
        rig.fire()
        #expect(rig.enters == 1)
        #expect(rig.recorded("enter").last?["outcome"] as? String == "sent")
        // the end of another text in a capped composer is not this paste: the Enter waits
        let other = Rig(kind: .agy, submitDelay: 0.15)
        other.io.screen = Self.idle
        other.io.bracketedPasteEnabled = true
        other.send(text)
        other.io.screen = ([Self.rule, "> ↑ 7 more lines", "  the end of something else, not what the bus pasted"]
                           + [Self.rule, Self.status]).joined(separator: "\n")
        other.fire()
        #expect(other.enters == 0)
        #expect(other.recorded("enter").last?["outcome"] as? String == "owed")
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

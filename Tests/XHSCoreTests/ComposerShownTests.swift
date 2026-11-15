import Foundation
import Testing
@testable import XHSCore

/// D35.1: the bus types only into a composer it can see. The composers are as four panes drew them on
/// 2026-11-15 (Claude Code 2.1, Codex 0.166); the question dialog is the one in the D7 picture of 2026-11-10;
/// the permission dialogs follow the harnesses' own layout, a title, the command, then numbered choices with
/// the mark on the highlighted one.
@Suite struct ComposerShownTests {
    static let claudeFoot = """
      Usage: 5h n/a, resets at n/a · week 56% left | Ctx: 444k / 1000k | Model: Fable 5.2 | Thinking: HIGH
      ⏵⏵ bypass permissions on · 2 shells · ← 4 agents
    """

    static func claude(_ composer: String) -> String {
        """
        ✳ Whisking… (17s · ↓ 818 tokens)
                                                              ✔ Update installed · Restart to apply
        ───────────────────────────────────────────────────────────────────────────── fable ─
        \(composer)
        ─────────────────────────────────────────────────────────────────────────────────────
        \(claudeFoot)
        """
    }

    /// Claude Code asks a question: tabs under a rule, the choices, a rule, one more choice, the keys.
    static func claudeQuestion(cursorOn chosen: Int) -> String {
        func row(_ n: Int, _ text: String) -> String { (n == chosen ? "❯ " : "  ") + "\(n). " + text }
        return """
        ⏺ Yes for some of them. D7 needs a pane stopped at a prompt, so I'll use my own.

        ─────────────────────────────────────────────────────────────────────────────────────
        ← ☐ D7 ring  ☐ D3 banner  ☐ D2 close  ✔ Submit  →

        This dialog IS the Dojo D7 test: my pane is now stopped at a prompt.

        \(row(1, "Ring and count both show"))
             The fable pane has a coral ring and the All tab shows 1.
        \(row(2, "Ring only"))
             The pane has the ring, but the All tab shows no count.
        \(row(3, "Neither shows"))
        \(row(4, "Type something."))
        ─────────────────────────────────────────────────────────────────────────────────────
        \(row(5, "Chat about this"))

        Enter to select · Tab/Arrow keys to navigate · Esc to cancel
        ───────────────────────────────────────────────────────────────────────────── fable ─
        """
    }

    static func claudePermission(cursorOn chosen: Int) -> String {
        func row(_ n: Int, _ text: String) -> String { (n == chosen ? " ❯ " : "   ") + "\(n). " + text }
        return """
        ⏺ Bash(rm -rf build)

        ─────────────────────────────────────────────────────────────────────────────────────
         Bash command

           rm -rf build
           Remove the build folder

         Do you want to proceed?
        \(row(1, "Yes"))
        \(row(2, "Yes, and don't ask again for: rm:*"))
        \(row(3, "No, and tell Claude what to do differently (esc)"))

         Esc to cancel · Tab to amend
        """
    }

    static func codex(_ composer: String) -> String {
        """
          Worked for 5m 25s • 16:23


        \(composer)

          GPT-6.1-Sol high · ~/AI_projects/origin · GPT-6.1-Sol · 5h 77% left · weekly 61% left · Full Access · Context 62% used · 828K
          window
          ← for agents · ? for shortcuts                                              ⚠ 2 warnings · f2 to view
        """
    }

    static func codexApproval(cursorOn chosen: Int, prompt: String = "› remove the build folder") -> String {
        func row(_ n: Int, _ text: String) -> String { (n == chosen ? "› " : "  ") + "\(n). " + text }
        return """
        \(prompt)

        • I'll remove the build folder.

          Would you like to run the following command?

          $ rm -rf build

        \(row(1, "Yes, proceed (y)"))
        \(row(2, "Yes, and don't ask again for commands that start with `rm -rf build` (p)"))
        \(row(3, "No, and tell Codex what to do differently (esc)"))

          Press enter to confirm or esc to cancel
        """
    }

    @Test func claudesComposerIsSeenEmptyOrNot() {
        for composer in ["❯\u{a0}", "❯", "❯ Try \"fix the failing test\"", "❯ [from: fable] status?", "❯ [Pasted text #1 +12 lines]"] {
            #expect(Composer.shown(kind: .claude, screen: Self.claude(composer)) == true, "\(composer)")
        }
        // text over several rows, with an empty row in it
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯ [from: fable] one\n  two\n\n  four")) == true)
    }

    @Test func aClaudeDialogIsNotAComposerWhereverItsMarkStands() {
        for chosen in 1...5 {
            // 5 is the trap: the mark stands right under a ruled line, as the composer's does
            #expect(Composer.shown(kind: .claude, screen: Self.claudeQuestion(cursorOn: chosen)) == false, "question, choice \(chosen)")
        }
        for chosen in 1...3 {
            #expect(Composer.shown(kind: .claude, screen: Self.claudePermission(cursorOn: chosen)) == false, "permission, choice \(chosen)")
        }
    }

    @Test func aPastPromptInClaudesTranscriptIsNotAComposer() {
        // past prompts carry the mark too, but stand after an empty row, not under a rule
        let screen = "⏺ done.\n\n❯ and now remove the build folder\n\n" + Self.claudePermission(cursorOn: 1)
        #expect(Composer.shown(kind: .claude, screen: screen) == false)
    }

    @Test func aRuledLineFarUpTheTranscriptIsNotTheComposers() {
        // a ruled line and a quoted row in an answer, then a dialog: before the bus has typed anything the
        // composer is at the foot of the screen, and nothing further up is taken for it
        let answer = "──────────────────────────────\n> a quoted line in the answer\n" + (1...6).map { "line \($0) of the answer" }.joined(separator: "\n")
        #expect(Composer.shown(kind: .claude, screen: answer + "\n" + Self.claudePermission(cursorOn: 1)) == false)
        // the composer itself, with the same answer above it, is seen
        #expect(Composer.shown(kind: .claude, screen: answer + "\n" + Self.claude("❯")) == true)
    }

    @Test func codexsComposerIsSeenEmptyOrNot() {
        for composer in ["› Ask Codex to do anything", "›", "› Ask Codex to do anything" + String(repeating: " ", count: 60) + "4 on 17 Nov · /status",
                         "› [from: fable] status?"] {
            #expect(Composer.shown(kind: .codex, screen: Self.codex(composer)) == true, "\(composer)")
        }
        #expect(Composer.shown(kind: .codex, screen: ComposerTests.codex("› Ask Codex to do anything")) == true)
        #expect(Composer.shown(kind: .codex, screen: ">_ OpenAI Codex (v0.165.0)\n\n› Ask Codex to do anything\n? for shortcuts") == true)
    }

    @Test func aCodexDialogIsNotAComposerWhereverItsMarkStands() {
        for chosen in 1...3 {
            #expect(Composer.shown(kind: .codex, screen: Self.codexApproval(cursorOn: chosen)) == false, "choice \(chosen)")
            #expect(Composer.shown(kind: .codex, screen: Self.codexApproval(cursorOn: chosen), afterPaste: true) == false, "choice \(chosen)")
        }
    }

    @Test func aPastPromptInCodexsTranscriptIsNotAComposer() {
        // a dialog with no mark of its own under a past prompt: the lowest mark is the transcript's
        let screen = Self.codexApproval(cursorOn: 0) + "\n\n  one more line\n  and another\n  and a third"
        #expect(Composer.shown(kind: .codex, screen: screen) == false)
        // a past prompt that does not follow an empty row
        #expect(Composer.shown(kind: .codex, screen: "• Working\n› resume\n\n  status") == false)
    }

    @Test func theBussOwnPasteMayFillRowsUnderCodexsMark() {
        let pasted = "› [from: fable] one\n  two\n\n  four\n  five\n  six\n  seven\n  eight\n  nine"
        #expect(Composer.shown(kind: .codex, screen: Self.codex(pasted), afterPaste: true) == true)
        // before anything is typed that many rows under the mark are a transcript
        #expect(Composer.shown(kind: .codex, screen: Self.codex(pasted)) == false)
    }

    @Test func aScreenWithNoComposerShowsNone() {
        for kind in [HarnessKind.claude, .codex] {
            #expect(Composer.shown(kind: kind, screen: "") == false)
            #expect(Composer.shown(kind: kind, screen: "Select model\n\n  1. Default\n  2. Other\n") == false)
        }
        // each harness is read by its own rule only
        #expect(Composer.shown(kind: .claude, screen: Self.codex("› Ask Codex to do anything")) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.claude("❯")) == false)
    }

    @Test func aHarnessWithoutARuleIsNotJudged() {
        for kind in [HarnessKind.pi, .shell, .runner] {
            #expect(Composer.shown(kind: kind, screen: "") == nil)
            #expect(Composer.shown(kind: kind, screen: Self.claudePermission(cursorOn: 1)) == nil)
        }
    }

    @Test func whatCountsAsARuledLineAndANumberedChoice() {
        #expect(Composer.isRuledLine("──────────── fable ─"))
        #expect(!Composer.isRuledLine("───"))
        #expect(!Composer.isRuledLine("- a list item"))
        #expect(Composer.isNumberedChoice("1. Yes"))
        #expect(Composer.isNumberedChoice("12. Chat about this"))
        #expect(!Composer.isNumberedChoice("1.5 times faster"))
        #expect(!Composer.isNumberedChoice("2026. A year"))
        #expect(!Composer.isNumberedChoice("[from: fable] 1. first"))
        #expect(!Composer.isNumberedChoice(""))
    }
}

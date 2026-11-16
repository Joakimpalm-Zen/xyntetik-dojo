import Foundation
import Testing
@testable import XHSCore

/// D35.1: the bus types only into a composer it can see, and presses Enter only once the composer holds what
/// it pasted. Where the screens come from is said at each fixture. Read off live panes on 2026-11-15: the
/// composers and footers of three Claude Code panes and one Codex pane, Claude Code's composer after a paste
/// of one line, of four lines and of 2,000 characters, and a Codex menu ("Approaching rate limits") that was
/// up while the bus called its pane idle. The question dialog is the one in a picture of a real pane from
/// 2026-11-10. The permission dialogs follow the harnesses' layout and were not captured.
@Suite struct ComposerShownTests {
    /// The rows under Claude Code's composer, as a pane had them: the owner's status line and a hint row.
    static let claudeFoot = """
      Usage: 5h n/a, resets at n/a · week 56% left | Ctx: 444k / 1000k | Model: Fable 5.2 | Thinking: HIGH
      ⏵⏵ bypass permissions on · 2 shells · ← 4 agents
    """

    static func claude(_ composer: String, foot: String = claudeFoot) -> String {
        """
        ✳ Whisking… (17s · ↓ 818 tokens)
                                                              ✔ Update installed · Restart to apply
        ───────────────────────────────────────────────────────────────────────────── fable ─
        \(composer)
        ─────────────────────────────────────────────────────────────────────────────────────
        \(foot)
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

    /// Under Codex's composer, as a pane had it: the status line, the word it wrapped onto, and the hints.
    static let codexFoot = """
      GPT-6.1-Sol high · ~/AI_projects/origin · GPT-6.1-Sol · 5h 77% left · weekly 61% left · Full Access · Context 62% used · 828K
      window
      ← for agents · ? for shortcuts                                              ⚠ 2 warnings · f2 to view
    """

    static func codex(_ composer: String, foot: String = codexFoot) -> String {
        """
          Worked for 5m 25s • 16:23


        \(composer)

        \(foot)
        """
    }

    /// Codex's own menu as a pane showed it on 2026-11-15, word for word, while the bus had the pane as idle:
    /// no hook reports this one. A message sent then would have been typed, and its Enter would have chosen.
    static let codexRateLimitMenu = """
          continues saying “Enter held, no composer on screen.”

      Worked for 14m 9s • 19:36


      Approaching rate limits
      Switch to gpt-6-luna for lower credit usage?


    › 1. Switch to gpt-6-luna                   Fast and affordable model for easier tasks.
      2. Keep current model
      3. Keep current model (never show again)  Hide future rate limit reminders about switching models

      enter select · esc back
    """

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

    // MARK: before the bus types

    @Test func claudesComposerIsSeenWhateverItsOneRowSays() {
        // empty; a suggestion; and what a pane showed after an Enter while it worked
        for composer in ["❯\u{a0}", "❯", "❯ Try \"fix the failing test\"", "❯ Press up to edit queued messages"] {
            #expect(Composer.shown(kind: .claude, screen: Self.claude(composer)) == true, "\(composer)")
        }
        // the hint row a pane showed after a paste, and no hint row at all
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "  Usage: 5h n/a | Ctx: 710k / 1000k\n  paste again to expand")) == true)
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "")) == true)
        // a status row that ends in a few ruled characters a wider line left behind, as a pane's did
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "  Usage: 5h n/a | Thinking: HIGH                  ─────────\n  ⏵⏵ bypass permissions on")) == true)
    }

    @Test func aComposerOfSeveralRowsIsNotTypedIntoUnasked() {
        // text the bus did not put there: the owner's, or what the harness put back after an interrupt
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯ a first row\n  and a second")) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› a first row\n  and a second")) == false)
    }

    @Test func codexsComposerIsSeenWhateverItsOneRowSays() {
        for composer in ["› Ask Codex to do anything", "›", "› Ask Codex to do anything" + String(repeating: " ", count: 60) + "4 on 17 Nov · /status"] {
            #expect(Composer.shown(kind: .codex, screen: Self.codex(composer)) == true, "\(composer)")
        }
        #expect(Composer.shown(kind: .codex, screen: ComposerTests.codex("› Ask Codex to do anything")) == true)
        // a fresh pane, before anything was asked
        #expect(Composer.shown(kind: .codex, screen: ">_ OpenAI Codex (v0.165.0)\n\n› Ask Codex to do anything\n\n  ? for shortcuts") == true)
    }

    // MARK: dialogs

    @Test func aClaudeDialogIsNotAComposerWhereverItsMarkStands() {
        for afterPaste in [false, true] {
            for chosen in 1...5 {
                // 5 is the trap: the mark stands right under a ruled line, as the composer's does
                #expect(Composer.shown(kind: .claude, screen: Self.claudeQuestion(cursorOn: chosen), afterPaste: afterPaste) == false,
                        "question, choice \(chosen)")
            }
            for chosen in 1...3 {
                #expect(Composer.shown(kind: .claude, screen: Self.claudePermission(cursorOn: chosen), afterPaste: afterPaste) == false,
                        "permission, choice \(chosen)")
            }
        }
    }

    @Test func codexsOwnMenuIsNotAComposer() {
        #expect(Composer.shown(kind: .codex, screen: Self.codexRateLimitMenu) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.codexRateLimitMenu, afterPaste: true) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.codexRateLimitMenu, afterPaste: true, pasted: "[from: fable] status?") == false)
        // with the highlight moved to the last choice
        let moved = Self.codexRateLimitMenu.replacingOccurrences(of: "› 1. Switch", with: "  1. Switch")
            .replacingOccurrences(of: "  3. Keep current model (never", with: "› 3. Keep current model (never")
        #expect(Composer.shown(kind: .codex, screen: moved) == false)
    }

    @Test func aCodexApprovalIsNotAComposerWhereverItsMarkStands() {
        for chosen in 0...3 {
            // 0: no choice carries the mark, and the lowest marked row is the prompt above the dialog
            #expect(Composer.shown(kind: .codex, screen: Self.codexApproval(cursorOn: chosen)) == false, "choice \(chosen)")
            #expect(Composer.shown(kind: .codex, screen: Self.codexApproval(cursorOn: chosen), afterPaste: true) == false, "choice \(chosen)")
        }
    }

    @Test func aPastPromptInTheTranscriptIsNotAComposer() {
        // Claude Code: past prompts carry the mark too, but stand after an empty row, not under a rule
        #expect(Composer.shown(kind: .claude, screen: "⏺ done.\n\n❯ and now remove the build folder\n\n" + Self.claudePermission(cursorOn: 1)) == false)
        // and a ruled line with a quoted row under it, further up an answer, is not the composer's
        let answer = "──────────────────────────────\n> a quoted line in the answer\n" + (1...6).map { "line \($0) of the answer" }.joined(separator: "\n")
        #expect(Composer.shown(kind: .claude, screen: answer + "\n" + Self.claudePermission(cursorOn: 1)) == false)
        #expect(Composer.shown(kind: .claude, screen: answer + "\n" + Self.claude("❯")) == true)
        // Codex: a past prompt that does not follow an empty row
        #expect(Composer.shown(kind: .codex, screen: "• Working\n› resume\n\n  status") == false)
    }

    /// The key hints are a list on top of the shape, never the only guard: each of these dialogs uses none of
    /// them, and none of them is numbered.
    @Test func aDialogWithNoKeyHintsIsHeldByItsShape() {
        // no ruled line closes it
        #expect(Composer.shown(kind: .claude, screen: "Trust this folder?\n──────────────────────\n❯ Yes, I trust it\n  No, exit") == false)
        // closed by a ruled line, with its other choice under that
        #expect(Composer.shown(kind: .claude, screen: "──────────────────────\n❯ Yes, I trust it\n──────────────────────\nNo, exit") == false)
        // closed by a ruled line, inside a frame
        #expect(Composer.shown(kind: .claude, screen: "──────────────────────\n❯ Yes, I trust it\n──────────────────────\n  │ No, exit │\n  ╰──────────╯") == false)
        // more under it than a footer has
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯ Yes", foot: "  one\n  two\n  three\n  four\n  five")) == false)
        // Codex: the other choice stands right under the marked one
        #expect(Composer.shown(kind: .codex, screen: "  Trust this folder?\n\n› Yes, continue\n  No, quit") == false)
        // Codex: under an empty row, text that is not set in as a footer is
        #expect(Composer.shown(kind: .codex, screen: "› Yes, continue\n\nNo, quit") == false)
        // Codex: a frame under it
        #expect(Composer.shown(kind: .codex, screen: "› Yes, continue\n\n  ╭──────────╮\n  │ No, quit │") == false)
    }

    @Test(arguments: Composer.dialogKeyHints)
    func aFooterWithADialogsKeyHintIsNotAFooter(hint: String) {
        // as written, in capitals, and after other words on the row
        for row in ["  " + hint, "  " + hint.uppercased(), "  Tab to switch · " + hint.capitalized + " · more"] {
            #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "  the status line\n" + row)) == false, "\(row)")
            #expect(Composer.shown(kind: .codex, screen: Self.codex("›", foot: "  the status line\n" + row)) == false, "\(row)")
        }
        // the same screens without the hint are composers
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "  the status line\n  a hint row")) == true)
        #expect(Composer.shown(kind: .codex, screen: Self.codex("›", foot: "  the status line\n  a hint row")) == true)
    }

    @Test func aNumberedRowUnderTheComposerIsNotAFooter() {
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯", foot: "  2. No")) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.codex("›", foot: "  2. Keep current model")) == false)
        // five columns wide: the number alone on its row
        #expect(Composer.shown(kind: .codex, screen: "Allow\nthis?\n\n› 1.\nYes\n  2.\nNo\n\nEnter\nto\nallow") == false)
    }

    // MARK: after the bus has pasted

    @Test func claudesComposerHoldsWhatTheBusPasted() {
        let line = "[from: claude-1] probe 1 of 3 for D35.1, sent by claude-1 to itself to see how the composer shows a pasted line. Ignore."
        // one line, as a pane showed it 0.15 seconds after the paste; the hint row had lost its last part
        let shown = Self.claude("❯ " + line, foot: "  Usage: 5h n/a | Ctx: 693k / 1000k\n  ⏵⏵ bypass permissions on · 1 shell")
        #expect(Composer.shown(kind: .claude, screen: shown, afterPaste: true, pasted: line) == true)
        // four lines and 2,000 characters, as the same pane showed them: a stand-in
        for standIn in ["❯ [Pasted text #10 +3 lines]", "❯ [Pasted text #11]"] {
            let screen = Self.claude(standIn, foot: "  Usage: 5h n/a | Ctx: 710k / 1000k\n  paste again to expand")
            #expect(Composer.shown(kind: .claude, screen: screen, afterPaste: true, pasted: "[from: fable] one\ntwo\n\nfour") == true, "\(standIn)")
        }
        // a line long enough to fill three rows of the composer, cut where the harness cut it
        let long = "[from: fable] " + (1...40).map { "word\($0)" }.joined(separator: " ")
        let rows = "❯ " + long.prefix(90) + "\n  " + long.dropFirst(90).prefix(90) + "\n  " + long.dropFirst(180)
        #expect(Composer.shown(kind: .claude, screen: Self.claude(rows), afterPaste: true, pasted: long) == true)
    }

    @Test func anEnterWaitsUntilTheComposerHoldsThePaste() {
        let pasted = "[from: fable] status?"
        // the text has not arrived: the composer is still empty, or still says what it said before
        for composer in ["❯", "❯ Press up to edit queued messages"] {
            #expect(Composer.shown(kind: .claude, screen: Self.claude(composer), afterPaste: true, pasted: pasted) == false, "\(composer)")
        }
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› Ask Codex to do anything"), afterPaste: true, pasted: pasted) == false)
        // something else is there
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯ [from: fable] status? and more"), afterPaste: true, pasted: pasted) == false)
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› [from: local] status?"), afterPaste: true, pasted: pasted) == false)
        // it is there
        #expect(Composer.shown(kind: .claude, screen: Self.claude("❯ [from: fable] status?"), afterPaste: true, pasted: pasted) == true)
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› [from: fable] status?"), afterPaste: true, pasted: pasted) == true)
    }

    @Test func theBussOwnPasteIsNotReadAsADialog() {
        // a message that quotes a choice, a quoted line and a numbered line: rows of the paste, set in
        let pasted = "[from: fable] Please explain this choice:\n› 1. Yes\n> quoted\n\n2. and a numbered line after an empty one"
        let rows = "› [from: fable] Please explain this choice:\n  › 1. Yes\n  > quoted\n\n  2. and a numbered line after an empty one"
        #expect(Composer.shown(kind: .codex, screen: Self.codex(rows), afterPaste: true, pasted: pasted) == true)
        // by the shape alone, with no word of what was pasted, the first empty row ends the composer
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› [from: fable] Please explain this choice:\n  › 1. Yes"), afterPaste: true) == true)
        // a long paste, as Codex stands in for one
        #expect(Composer.shown(kind: .codex, screen: Self.codex("› [Pasted Content 2040 chars]"), afterPaste: true, pasted: pasted) == true)
        // and before anything is typed, rows under the mark are not a one-row composer
        #expect(Composer.shown(kind: .codex, screen: Self.codex(rows)) == false)
    }

    @Test func aDialogUnderThePasteIsStillADialog() {
        // the paste is on the screen, in the transcript, and a dialog with no mark of its own stands under it
        let pasted = "[from: fable] remove the build folder"
        #expect(Composer.shown(kind: .codex, screen: Self.codexApproval(cursorOn: 0, prompt: "› " + pasted), afterPaste: true, pasted: pasted) == false)
    }

    // MARK: the cursor

    @Test func whereTheTerminalSaysTheCursorMustBeOnTheComposer() {
        let lines = Self.claude("❯").components(separatedBy: "\n")
        let composer = lines.firstIndex { $0.hasPrefix("❯") }!
        #expect(Composer.shown(kind: .claude, lines: lines, cursorLine: composer) == true)
        #expect(Composer.shown(kind: .claude, lines: lines, cursorLine: composer + 2) == false)
        #expect(Composer.shown(kind: .claude, lines: lines, cursorLine: 0) == false)
        // a terminal that does not say: the shape alone
        #expect(Composer.shown(kind: .claude, lines: lines, cursorLine: nil) == true)
        // after a paste the cursor may be on any row of the pasted text
        let pasted = "[from: fable] one\ntwo\nthree"
        let codex = Self.codex("› [from: fable] one\n  two\n  three").components(separatedBy: "\n")
        let first = codex.firstIndex { $0.hasPrefix("›") }!
        for row in first...(first + 2) {
            #expect(Composer.shown(kind: .codex, lines: codex, cursorLine: row, afterPaste: true, pasted: pasted) == true, "row \(row)")
        }
        #expect(Composer.shown(kind: .codex, lines: codex, cursorLine: first + 4, afterPaste: true, pasted: pasted) == false)
        // a long screen: the cursor's line is counted from the top of all of it
        let tall = (1...100).map { "line \($0)" } + lines
        #expect(Composer.shown(kind: .claude, lines: tall, cursorLine: 100 + composer) == true)
        #expect(Composer.shown(kind: .claude, lines: tall, cursorLine: composer) == false)
    }

    // MARK: the rest

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

    @Test func whatCountsAsARuledLineAChoiceAndAFrame() {
        #expect(Composer.isRuledLine("──────────── fable ─"))
        #expect(!Composer.isRuledLine("───"))
        #expect(!Composer.isRuledLine("- a list item"))
        #expect(Composer.isNumberedChoice("1. Yes"))
        #expect(Composer.isNumberedChoice("12. Chat about this"))
        #expect(Composer.isNumberedChoice("1."))
        #expect(!Composer.isNumberedChoice("1.5 times faster"))
        #expect(!Composer.isNumberedChoice("2026. A year"))
        #expect(!Composer.isNumberedChoice("[from: fable] 1. first"))
        #expect(!Composer.isNumberedChoice(""))
        #expect(Composer.startsWithBoxDrawing("│ No, exit │"))
        #expect(Composer.startsWithBoxDrawing("╰────╯"))
        #expect(!Composer.startsWithBoxDrawing("Usage: 5h n/a | Thinking: HIGH     ─────"))
    }
}

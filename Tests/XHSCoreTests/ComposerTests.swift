import Testing
@testable import XHSCore

/// Screens as the harnesses drew them, read off real panes on 2026-11-09 (Codex 0.166.0, Claude Code).
@Suite struct ComposerTests {
    static func codex(_ composer: String, under: String = "") -> String {
        """
        • Working (3m 24s • esc to interrupt)
          └ Tip: Paste an image with Ctrl+V to attach it to your next message.


        \(composer)
        \(under)
          GPT-6.1-Sol high · ~/project · 5h 99% left · weekly 56% left
          ? for shortcuts                                                  ⚠ 6 warnings · f2 to view

        """
    }

    static func claude(_ composer: String, under: String = "─────────────────────────────────────────") -> String {
        """
          the end of the last answer.
        ──────────────────────────────────────────────── Leader ─
        \(composer)
        \(under)
          Usage: 5h n/a · week 9% left | Ctx: 297k / 1000k | Model: Opus 5.5
          ⏵⏵ bypass permissions on (shift+tab to cycle) · ← 4 agents

        """
    }

    @Test func codexShowsItsPlaceholderWhenEmpty() {
        for placeholder in ["Ask Codex to do anything", "Ask a follow-up question", "Waiting for startup"] {
            #expect(Composer.shownEmpty(kind: .codex, screen: Self.codex("› " + placeholder)), "\(placeholder)")
        }
        #expect(Composer.shownEmpty(kind: .codex, screen: Self.codex("›")))
    }

    /// Codex 0.166.0 with the weekly limit low, read off a pane on 2026-11-13: the composer row carries a
    /// right-aligned hint after the placeholder. Four messages stayed queued for an idle pane because of it.
    @Test func codexPlaceholderWithItsUsageHintIsEmpty() {
        let row = "› Ask Codex to do anything" + String(repeating: " ", count: 119) + "4 on 17 Nov · /status"
        #expect(Composer.shownEmpty(kind: .codex, screen: Self.codex(row)))
        // One space and more words is the owner's text, hint or no hint.
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("› Ask Codex to do anything else" + String(repeating: " ", count: 40) + "4 on 17 Nov · /status")))
        // A hint after a draft does not make the draft a placeholder.
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("› resume the review" + String(repeating: " ", count: 40) + "4 on 17 Nov · /status")))
    }

    @Test func claudeShowsNothingAfterItsMarkWhenEmpty() {
        #expect(Composer.shownEmpty(kind: .claude, screen: Self.claude("❯\u{a0}")))
        #expect(Composer.shownEmpty(kind: .claude, screen: Self.claude("❯")))
    }

    @Test func aDraftIsNotEmpty() {
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("› resume the review")))
        #expect(!Composer.shownEmpty(kind: .claude, screen: Self.claude("❯\u{a0}resume the review")))
        // The placeholder's words typed as a draft, with more after them.
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("› Ask Codex to do anything else")))
    }

    @Test func aDraftOverTwoRowsIsNotEmpty() {
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("›", under: "  the second line of a draft")))
        #expect(!Composer.shownEmpty(kind: .claude, screen: Self.claude("❯\u{a0}", under: "  the second line of a draft")))
    }

    @Test func anUnknownPlaceholderKeepsTheHold() {
        #expect(!Composer.shownEmpty(kind: .codex, screen: Self.codex("› Ask Codex anything at all")))
    }

    @Test func aPastPromptInTheTranscriptIsNotTheComposer() {
        let screen = Self.codex("› resume the review").replacingOccurrences(of: "• Working", with: "›\n• Working")
        #expect(!Composer.shownEmpty(kind: .codex, screen: screen))
    }

    @Test func noComposerOnScreenIsNotEmpty() {
        #expect(!Composer.shownEmpty(kind: .codex, screen: ""))
        #expect(!Composer.shownEmpty(kind: .codex, screen: "› \n" + String(repeating: "transcript\n", count: 20)))
    }

    @Test func harnessesWithoutARuleNeverShowEmpty() {
        for kind in [HarnessKind.pi, .shell, .runner] {
            #expect(!Composer.shownEmpty(kind: kind, screen: Self.codex("›")))
            #expect(!Composer.shownEmpty(kind: kind, screen: Self.claude("❯")))
        }
    }

    @Test func eachHarnessReadsOnlyItsOwnMark() {
        #expect(!Composer.shownEmpty(kind: .claude, screen: Self.codex("› Ask Codex to do anything")))
    }
}

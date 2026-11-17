import Foundation
import Testing
@testable import XHSCore

/// D43 negative safety guards and end-to-end Bus.Rig Enter checks for the sweep shapes:
/// 10-row capped Claude without closing rule, primary-screen Claude without top rule,
/// Codex inline-scrolled multi-line paste, and capped banner wrap-count verification.
@MainActor @Suite struct D43ComposerFixTests {
    typealias Rig = PromptHookLostTests.Rig

    static let rule60 = String(repeating: "─", count: 60)
    static let claudeFoot60 = "  Usage: 5h n/a, resets at n/a · week 89% left"

    @Test func claudeTenRowWithoutClosingRuleRejectsNonPasteRows() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        let text = "single line message text for composer sweep check; "
            + "single line message text for composer sweep check; "
            + "single line message text for composer sweep check; "
            + "single line message text for composer sweep check; "
            + "single line message text for composer sweep check; single line"
        rig.io.screen = [Self.rule60, "❯\u{a0}", Self.rule60, Self.claudeFoot60].joined(separator: "\n")
        rig.send(text)
        // Dialog choice or mid-scroll `↓` under the banner must hold Enter even with no closing rule.
        for bad in [
            ["  1. Yes", "  2. No"],
            ["  composer sweep check; single line", "  ─── ↓ 1 more ────────────────"],
            ["  something unrelated to this paste"],
        ] {
            rig.io.screen = (["─── ↑ 3 more " + String(repeating: "─", count: 47)] + bad).joined(separator: "\n")
            let held = Composer.holding(kind: .claude, lines: rig.io.screen.components(separatedBy: "\n"),
                                        cursorLine: nil, pasted: "[from: coder] " + text,
                                        before: Composer.Look(composer: "", under: [Self.claudeFoot60]))
            #expect(held == nil, "\(bad)")
        }
    }

    @Test func claudePrimaryScreenRejectsDialogsOrMissingFooter() {
        let paste = "[from: probe] single line message text for composer sweep check; "
            + "single line message text for composer sweep check; single line"
        let before = Composer.Look(composer: "", under: [Self.claudeFoot60])
        // A closing rule without any footer under it is indistinguishable from a truncated box.
        let noFooter = [
            "  single line message text for composer sweep check; single line",
            Self.rule60,
        ]
        #expect(Composer.holding(kind: .claude, lines: noFooter, cursorLine: nil, pasted: paste, before: before) == nil)
        // A dialog key hint below the closing rule must still hold.
        let dialogFooter = [
            "  single line message text for composer sweep check; single line",
            Self.rule60,
            "  1. Allow",
            "  Enter to select · Esc to cancel",
        ]
        #expect(Composer.shown(kind: .claude, lines: dialogFooter, cursorLine: nil, afterPaste: true, pasted: paste, before: before) == false)
    }

    @Test func codexInlineScrollRejectsDownArrowOrDialogBelow() {
        let paste = "[from: probe] line 01: alpha\n line 02: beta\n line 03: gamma\n line 04: delta"
        let before = Composer.Look(composer: "Ask Codex to do anything", under: ["? for shortcuts"])
        // Mid-scrolled (`↓`) must wait; it is not at the end of the paste.
        let scrolledMid = [
            "",
            "›  line 02: beta↑",
            "   line 03: gamma↓",
        ]
        #expect(Composer.holding(kind: .codex, lines: scrolledMid, cursorLine: nil, pasted: paste, before: before) == nil)
        // Dialog row added below the tail must hold via footerUnchanged and key hints.
        let withDialog = [
            "",
            "›  line 02: beta↑",
            "   line 03: gamma",
            "   line 04: delta",
            "  1. Yes, allow",
            "  Enter to confirm",
        ]
        #expect(Composer.shown(kind: .codex, lines: withDialog, cursorLine: nil, afterPaste: true, pasted: paste, before: before) == false)
    }
}

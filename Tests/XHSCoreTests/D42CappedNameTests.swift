import Foundation
import Testing
@testable import XHSCore

/// D42, live on 2026-11-17: in a Claude Code session renamed with /rename, the capped composer's top line carries
/// the session's name at its right end ("─── ↑ 4 more ───…─── d42-probe ─", read off Claude Code 2.1.326 in a pty,
/// Tests/XHSAppTests/Fixtures has the bytes). D41's rule wanted only box-drawing characters after "more", so the
/// line was not the composer's top, and the bus held the Enter ("no composer on the screen") until the owner
/// pressed it.
@MainActor @Suite struct D42CappedNameTests {
    typealias Rig = PromptHookLostTests.Rig

    static let rule = String(repeating: "─", count: 105)
    static let named = "─── ↑ 4 more " + String(repeating: "─", count: 80) + " d42-probe ─"

    @Test func aCappedTopLineWithTheSessionsNameIsOne() {
        #expect(Composer.isCappedRule(Self.named, "↑"))
        // read off Claude Code at 60 columns as well: three box characters before the arrow at either width
        #expect(Composer.isCappedRule("─── ↑ 8 more " + String(repeating: "─", count: 34) + " supervisor ─", "↑"))
        #expect(Composer.isCappedRule("─── ↑ 3 more ───────", "↑"), "D41's line, no name")
        #expect(Composer.isCappedRule("─── ↑ 2 more ─────── my session ─", "↑"), "a name with a blank in it")
        // not one: text after "more" that the line does not close, a count that is no number, no line before it
        #expect(!Composer.isCappedRule("─── ↑ 4 more and then some words", "↑"))
        #expect(!Composer.isCappedRule("─── ↑ 4 more ─── d42-probe", "↑"), "the name is closed by the line's last run")
        #expect(!Composer.isCappedRule("─── ↑ three more ─── d42-probe ─", "↑"))
        #expect(!Composer.isCappedRule("↑ 4 more ─── d42-probe ─", "↑"))
    }

    /// The bus's paste in a renamed session's capped composer gets its Enter, on the screen's shape as recorded.
    @Test func aPasteInARenamedSessionsCappedComposerGetsItsEnter() {
        let text = "D42, a relayed message of about the shape the owner saw: several sentences in one paragraph, long enough "
            + "that the composer wraps it over many rows of a short pane. It names nothing real and asks for nothing; it is "
            + "here so that Claude Code caps the composer's height and writes how many rows it does not show. The second "
            + "part keeps the text going with plain words, so that the wrapped rows outnumber what a pane of this height "
            + "lets the composer show, and the top line of the composer carries the arrow and the count."
        let foot = "  Usage: 5h n/a, resets at n/a · week 92% left | Ctx: 0 / 1000k | Model: Fable 5.2 | Thinking: HIGH"
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = ["❯ /rename d42-probe", "  ⎿  Session renamed to: d42-probe", "",
                         String(repeating: "─", count: 93) + " d42-probe ─", "❯\u{a0}", Self.rule, foot].joined(separator: "\n")
        rig.send(text)
        rig.io.screen = ["❯ /rename d42-probe", "  ⎿  Session renamed to: d42-probe",
                         String(repeating: " ", count: 82) + "ctrl+g to edit in Vim", Self.named,
                         "  wrapped rows outnumber what a pane of this height lets the composer show, and the top line of the",
                         "  composer carries the arrow and the count.", Self.rule, foot].joined(separator: "\n")
        rig.fire()
        #expect(rig.enters == 1, "\(rig.recorded("enter"))")
        #expect(rig.recorded("enter").last?["outcome"] as? String == "sent")
    }
}

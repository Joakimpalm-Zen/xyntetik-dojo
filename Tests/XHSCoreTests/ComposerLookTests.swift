import Foundation
import Testing
@testable import XHSCore

/// D35.1, third round: the Enter is pressed against the look the bus took when it typed. The screens are
/// the rows from the composer down, read off live panes on 2026-11-15 while a message was sent to each and
/// the pane was sampled: Claude Code with one line, four lines and 2,000 characters, Codex the same while
/// idle, and Codex with one line while it worked.
@Suite struct ComposerLookTests {
    static let rule = String(repeating: "─", count: 100)
    static let claudeStatus = "  Usage: 5h n/a, resets at n/a · week 48% left | Ctx: 693k / 1000k | Model: Fable 5.2 | Thinking: HIGH"
    static let codexStatus = """
      GPT-6.1-Sol high · ~/AI_projects/origin · GPT-6.1-Sol · 5h 60% left · weekly 44% left · Full Access · Context 63% used · 828K
      window
    """
    static let codexHints = "  ← for agents · ? for shortcuts" + String(repeating: " ", count: 71) + "⚠ 4 warnings · f2 to view"
    static let codexHintsWithText = String(repeating: " ", count: 103) + "⚠ 4 warnings · f2 to view"

    static func claude(_ composer: String, hints: String) -> [String] {
        ["● done", "", rule, composer, rule, claudeStatus, hints]
    }

    static func codex(_ composer: String, hints: String, working: Bool = false) -> [String] {
        (working ? ["• Working (3m 25s • esc to interrupt)", ""] : ["  Worked for 5m 25s • 16:23", ""])
            + [""] + composer.components(separatedBy: "\n") + [""] + codexStatus.components(separatedBy: "\n") + [hints]
    }

    /// One real pair: the screen the bus typed into, the screen its Enter met, and what it had pasted.
    struct Pair: CustomTestStringConvertible, Sendable {
        var testDescription: String
        var kind: HarnessKind
        var before: [String]
        var after: [String]
        var pasted: String
    }

    static let pairs: [Pair] = [
        Pair(testDescription: "Claude Code, one line: the hint row loses its last part", kind: .claude,
             before: claude("❯ ", hints: "  ⏵⏵ bypass permissions on · 1 shell · ← 4 agents"),
             after: claude("❯ [from: claude-1] probe 1 of 3 for D35.1", hints: "  ⏵⏵ bypass permissions on · 1 shell"),
             pasted: "[from: claude-1] probe 1 of 3 for D35.1"),
        Pair(testDescription: "Claude Code, four lines: a stand-in, and the hint row is a new one", kind: .claude,
             before: claude("❯ ", hints: "  ⏵⏵ bypass permissions on · 1 shell · ← 4 agents"),
             after: claude("❯ [Pasted text #10 +3 lines]", hints: "  paste again to expand"),
             pasted: "[from: claude-1] probe 2\n> a quoted second line\n\n1. a numbered fourth line"),
        Pair(testDescription: "Claude Code, 2,000 characters, a message queued before it", kind: .claude,
             before: claude("❯ Press up to edit queued messages", hints: "  paste again to expand"),
             after: claude("❯ [Pasted text #11]", hints: "  paste again to expand"),
             pasted: "[from: claude-1] " + String(repeating: "long ", count: 400)),
        Pair(testDescription: "Codex idle, one line over two rows: the hint row keeps its right part", kind: .codex,
             before: codex("› Ask Codex to do anything", hints: codexHints),
             after: codex("› [from: claude-1] Probe 1 of 3 for Dojo D35.1: one line, to see how your composer shows it.\n  Please answer with the one word ok.", hints: codexHintsWithText),
             pasted: "[from: claude-1] Probe 1 of 3 for Dojo D35.1: one line, to see how your composer shows it. Please answer with the one word ok."),
        Pair(testDescription: "Codex idle, four lines with an empty one", kind: .codex,
             before: codex("› Ask Codex to do anything", hints: codexHints),
             after: codex("› [from: claude-1] Probe 2 of 3: four lines.\n  > a quoted second line\n\n  1. a numbered fourth line after an empty one.", hints: codexHintsWithText),
             pasted: "[from: claude-1] Probe 2 of 3: four lines.\n> a quoted second line\n\n1. a numbered fourth line after an empty one."),
        Pair(testDescription: "Codex idle, 2,000 characters: a stand-in", kind: .codex,
             before: codex("› Ask Codex to do anything", hints: codexHints),
             after: codex("› [Pasted Content 2011 chars]", hints: codexHintsWithText),
             pasted: "[from: claude-1] " + String(repeating: "long ", count: 400)),
        Pair(testDescription: "Codex at work, one line: the hint row is a new one", kind: .codex,
             before: codex("› Ask Codex to do anything", hints: codexHints, working: true),
             after: codex("› [from: claude-1] D35.1 probe from claude-1, sent while you work.", hints: "  tab to queue message", working: true),
             pasted: "[from: claude-1] D35.1 probe from claude-1, sent while you work."),
    ]

    @Test(arguments: ComposerLookTests.pairs)
    func theEnterIsPressedOnEveryScreenARealPaneShowedAfterAPaste(_ pair: Pair) throws {
        let before = try #require(Composer.look(kind: pair.kind, lines: pair.before, cursorLine: nil), "the bus types into this composer")
        #expect(Composer.shown(kind: pair.kind, lines: pair.after, cursorLine: nil, afterPaste: true, pasted: pair.pasted, before: before) == true)
    }

    /// The other direction, on the same real screens: a dialog that opens under the composer while the pasted
    /// text still stands in it. Its rows are set in as a footer's are and carry no key hint, so only the look
    /// before the paste tells them from a footer.
    @Test(arguments: ComposerLookTests.pairs)
    func aRowThatWasNotUnderTheComposerBeforeThePasteHoldsTheEnter(_ pair: Pair) throws {
        let before = try #require(Composer.look(kind: pair.kind, lines: pair.before, cursorLine: nil))
        for added in ["  Allow this action?", "  Yes / No", "  Do you trust the files in this folder?"] {
            var after = pair.after
            after.insert(added, at: after.count - 1)
            #expect(Composer.shown(kind: pair.kind, lines: after, cursorLine: nil, afterPaste: true, pasted: pair.pasted, before: before) == false,
                    "\(added) was not there before")
            // and in place of the hint row
            after = pair.after
            after[after.count - 1] = added
            #expect(Composer.shown(kind: pair.kind, lines: after, cursorLine: nil, afterPaste: true, pasted: pair.pasted, before: before) == false)
        }
    }

    @Test func aStatusLineThatCountsOnIsTheSameRow() {
        #expect(Composer.wasThere("Ctx: 694k / 1000k | 5h 59% left", "Ctx: 693k / 1000k | 5h 60% left"))
        #expect(Composer.wasThere("⏵⏵ bypass permissions on · 1 shell", "⏵⏵ bypass permissions on · 1 shell · ← 4 agents"))
        #expect(Composer.wasThere("⚠ 4 warnings · f2 to view", "← for agents · ? for shortcuts      ⚠ 4 warnings · f2 to view"))
        // a short word is not looked for inside a row, and the middle of a row is not a part of it
        #expect(!Composer.wasThere("Yes", "Yes, and do not ask again for this folder"))
        #expect(!Composer.wasThere("permissions on", "⏵⏵ bypass permissions on · 1 shell"))
        #expect(!Composer.wasThere("Allow this action?", "⏵⏵ bypass permissions on · 1 shell"))
    }

    /// A composer that already shows a stand-in holds a paste that is not the bus's: typing there would add
    /// to it, and at the Enter the stand-in could not be told from the bus's own.
    @Test func aComposerThatAlreadyShowsAStandInIsNotTypedInto() {
        #expect(Composer.look(kind: .claude, lines: Self.claude("❯ [Pasted text #7]", hints: "  paste again to expand"), cursorLine: nil) == nil)
        #expect(Composer.look(kind: .codex, lines: Self.codex("› [Pasted Content 2000 chars]", hints: Self.codexHints), cursorLine: nil) == nil)
        // and a stand-in that has not changed since the look is not this paste
        let before = Composer.Look(composer: "[Pasted text #7]", under: [])
        #expect(!Composer.arrived("new", rows: ["[Pasted text #7]"], standIn: "[Pasted text #", before: before))
        #expect(Composer.arrived("new", rows: ["[Pasted text #8]"], standIn: "[Pasted text #", before: before))
    }

    /// A key hint is a few words of a hint row, not letters inside a path or a longer word.
    @Test func aKeyHintStartsAWordOfAHintRow() {
        #expect(Composer.hasKeyHint("enter select · esc back"))
        #expect(Composer.hasKeyHint("Press enter to confirm or esc to go back"))
        #expect(Composer.hasKeyHint("↑↓ to move      Enter to select"))
        #expect(!Composer.hasKeyHint("GPT-6.1-Sol high · ~/press enter · GPT-6.1-Sol"))
        #expect(!Composer.hasKeyHint("branch fix/esc back · main"))
        #expect(!Composer.hasKeyHint("tab to queue message"))
        #expect(!Composer.hasKeyHint("⏵⏵ bypass permissions on (shift+tab to cycle) · esc to interrupt"))
    }
}

/// D35.1, third round, through the bus.
@MainActor @Suite struct ComposerLookBusTests {
    typealias Rig = PromptHookLostTests.Rig

    /// A pager or an editor the owner opened shows in the terminal's other buffer, and a file in it can
    /// read as a composer. The bus knows the harness's buffer from the last hook that had the harness at its
    /// composer, and types nothing while the other one shows.
    @Test(arguments: [false, true])
    func nothingIsTypedWhileTheOtherBufferShows(harnessDrawsInTheAlternateBuffer home: Bool) {
        let rig = Rig(kind: .codex, submitDelay: 0.15)
        rig.io.alternate = home
        rig.hook("Stop")
        rig.io.alternate = !home
        rig.io.screen = ComposerShownTests.codex("› file contents")
        #expect(rig.send("status?")["delivered"] as? Bool == false)
        #expect(rig.io.written.isEmpty)
        #expect(rig.bus.info("worker")?.noComposer == true)
        // back in the harness's own buffer, the message goes out
        rig.io.alternate = home
        rig.wait(3)
        #expect(rig.io.typed.contains("status?"))
        #expect(rig.bus.info("worker")?.noComposer == false)
    }

    @Test func theEnterIsHeldWhileTheOtherBufferShows() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.alternate = true
        rig.hook("Stop")
        rig.send("status?")
        rig.io.alternate = false
        rig.fire()
        #expect(rig.enters == 0)
        rig.io.alternate = true
        rig.wait(3)
        #expect(rig.enters == 1)
    }

    /// A harness may report its start before it has drawn itself, so the start is not where the buffer is
    /// learned; and a pane that cannot say which buffer shows is typed into by its screen alone.
    @Test func theBufferIsLearnedOnlyFromAHookThatHasTheHarnessAtItsComposer() {
        let early = Rig(kind: .claude, submitDelay: 0.15)   // its SessionStart came with `alternate` unset
        early.io.alternate = false
        early.hook("SessionStart")
        early.io.alternate = true
        #expect(early.send("status?")["delivered"] as? Bool == true, "nothing learned at the start, so nothing to differ from")
        early.fire()
        #expect(early.enters == 1)

        let silent = Rig(kind: .claude, submitDelay: 0.15)
        silent.hook("Stop")
        #expect(silent.send("status?")["delivered"] as? Bool == true, "the pane does not say: as before")

        let sent = Rig(kind: .claude, submitDelay: 0.15)
        sent.io.alternate = true
        sent.hook("UserPromptSubmit")
        sent.io.alternate = false
        #expect(sent.send("status?")["delivered"] as? Bool == false, "a prompt sent from the composer shows the harness's buffer too")
        // a new session forgets it: the next harness in the pane may draw itself in the other buffer
        sent.hook("SessionStart")
        sent.wait(3)
        #expect(sent.io.typed.contains("status?"))
    }

    /// The owner sends or empties the composer in the moment before the bus's Enter: the record says the
    /// Enter was dropped, and none is owed.
    @Test func anEnterTheOwnerMadeNeedlessIsDroppedAndRecorded() {
        for key in [Bus.OwnerKey.submit, .clear] {
            let rig = Rig(kind: .claude, submitDelay: 0.15)
            rig.send("first")
            rig.clock += 0.05
            rig.bus.noteOwnerInput("worker", key)
            rig.fire()
            #expect(rig.enters == 0, "the text is the owner's to send, or gone")
            let enter = rig.recorded("enter")
            #expect(enter.count == 1)
            #expect(enter.first?["outcome"] as? String == "dropped")
            #expect(rig.bus.info("worker")?.noComposer == false)
        }
    }

    /// A dialog under the bus's own paste, through the bus, with rows that a footer could have: held by the
    /// look, and pressed once the rows under the composer are the old ones again.
    @Test func theOwedEnterGoesOutOnceTheRowsUnderTheComposerAreTheOldOnesAgain() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = ComposerShownTests.claude("❯ ")
        rig.send("status?")
        rig.io.screen = ComposerShownTests.claude("❯ [from: fable] status?", foot: ComposerShownTests.claudeFoot + "\n  Allow this action?")
        rig.fire()
        #expect(rig.enters == 0)
        #expect(rig.bus.info("worker")?.noComposer == true)
        rig.io.screen = ComposerShownTests.claude("❯ [from: fable] status?")
        rig.wait(3)
        #expect(rig.enters == 1)
        #expect(rig.bus.info("worker")?.noComposer == false)
    }
}

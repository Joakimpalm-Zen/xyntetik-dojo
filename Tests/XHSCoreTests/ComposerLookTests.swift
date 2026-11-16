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

    /// What counts as a row that was there: the row itself with its numbers moved on, or that row with whole
    /// parts taken away. A row that has gained anything is new.
    @Test func aRowWasThereOnlyAsItWasOrWithWholePartsTakenAway() {
        // numbers move on, also across a digit boundary
        #expect(Composer.wasThere("Ctx: 694k / 1000k | 5h 59% left", "Ctx: 693k / 1000k | 5h 60% left"))
        #expect(Composer.wasThere("Context: 10% used", "Context: 9% used"))
        #expect(Composer.wasThere("Context: 9% used", "Context: 100% used"))
        // whole parts taken away: at the middle dot, and at the gap Codex leaves between left and right
        #expect(Composer.wasThere("⏵⏵ bypass permissions on · 1 shell", "⏵⏵ bypass permissions on · 1 shell · ← 4 agents"))
        #expect(Composer.wasThere("⚠ 4 warnings · f2 to view", "← for agents · ? for shortcuts      ⚠ 4 warnings · f2 to view"))
        #expect(Composer.wasThere("⏵⏵ bypass permissions on · ← 4 agents", "⏵⏵ bypass permissions on · 1 shell · ← 4 agents"))
        // gained a part, or text inside a part: new
        #expect(!Composer.wasThere("⏵⏵ bypass permissions on · Allow this action?", "⏵⏵ bypass permissions on"))
        #expect(!Composer.wasThere("⏵⏵ bypass permissions on · 1 shell · ← 4 agents", "⏵⏵ bypass permissions on · 1 shell"))
        #expect(!Composer.wasThere("⏵⏵ bypass permissions on? Yes", "⏵⏵ bypass permissions on"))
        #expect(!Composer.wasThere("Allow    ⚠ 4 warnings", "⚠ 4 warnings"))
        // a piece of a part is not a part, and the order of the parts is kept
        #expect(!Composer.wasThere("Yes", "Yes, and do not ask again for this folder"))
        #expect(!Composer.wasThere("permissions on", "⏵⏵ bypass permissions on · 1 shell"))
        #expect(!Composer.wasThere("1 shell · ⏵⏵ bypass permissions on", "⏵⏵ bypass permissions on · 1 shell"))
        #expect(!Composer.wasThere("Allow this action?", "⏵⏵ bypass permissions on · 1 shell"))
        #expect(!Composer.wasThere("", "⏵⏵ bypass permissions on"))
    }

    /// The rows are matched one for one, in their order: a row that was added is new even when it reads
    /// like a part of an old one, and the harness's own hint stands in the place of one row from before.
    @Test func theRowsUnderTheComposerAreMatchedOneForOne() {
        let before = ["GPT-6.1-Sol · Full Access", "← for agents · ? for shortcuts"]
        #expect(Composer.footerUnchanged(before, since: before, kind: .codex))
        #expect(Composer.footerUnchanged(["GPT-6.1-Sol · Full Access"], since: before, kind: .codex), "a row less")
        #expect(Composer.footerUnchanged(["GPT-6.1-Sol · Full Access", "tab to queue message"], since: before, kind: .codex))
        #expect(Composer.footerUnchanged(["tab to queue message"], since: before, kind: .codex))
        #expect(Composer.footerUnchanged([], since: before, kind: .codex))
        // added rows
        #expect(!Composer.footerUnchanged(["GPT-6.1-Sol · Full Access", "Full Access", "← for agents · ? for shortcuts"], since: before, kind: .codex))
        #expect(!Composer.footerUnchanged(["GPT-6.1-Sol · Full Access", "Full Access"], since: ["GPT-6.1-Sol · Full Access"], kind: .codex))
        #expect(!Composer.footerUnchanged(["GPT-6.1-Sol", "Full Access"], since: ["GPT-6.1-Sol · Full Access"], kind: .codex), "one old row cannot be two")
        #expect(!Composer.footerUnchanged(before + ["tab to queue message"], since: before, kind: .codex), "the hint takes a row's place, it is not one more")
        // out of their order
        #expect(!Composer.footerUnchanged(before.reversed(), since: before, kind: .codex))
        // the other harness's hint is not this one's
        #expect(!Composer.footerUnchanged(["GPT-6.1-Sol · Full Access", "paste again to expand"], since: before, kind: .codex))
    }

    /// A limit, stated in the guide: the parts of a row are divided at a middle dot and at a gap, so a
    /// folder whose name holds one of those and then a key hint reads as a hint, and holds the pane.
    @Test func aFolderNamedWithASeparatorAndAHintHoldsThePane() {
        #expect(Composer.hasKeyHint("GPT-6.1-Sol · ~/project  press enter · Full Access"))
        #expect(Composer.hasKeyHint("GPT-6.1-Sol · ~/project · press enter · Full Access"))
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

    /// A key hint is whole words, wherever in a row they stand; a part of the row that is a path is never
    /// one.
    @Test func aKeyHintIsWholeWordsOutsideAPath() {
        #expect(Composer.hasKeyHint("enter select · esc back"))
        #expect(Composer.hasKeyHint("Press enter to confirm or esc to go back"))
        #expect(Composer.hasKeyHint("↑↓ to move      Enter to select"))
        #expect(Composer.hasKeyHint("Tab to switch · Enter Select · more"))
        #expect(Composer.hasKeyHint("(enter select)"))
        #expect(Composer.hasKeyHint("Do you want this? [press enter]"))
        #expect(Composer.hasKeyHint("Enter to select · Tab/Arrow keys to navigate · Esc to cancel"))
        // a slash in a hint row does not make it a path
        #expect(Composer.hasKeyHint("Use ↑/↓ and Enter to select"))
        #expect(Composer.hasKeyHint("Press Enter to confirm, Esc/Ctrl+C to cancel"))
        #expect(Composer.hasKeyHint("(y/n) press enter to confirm"))
        // the owner's status: a path begins at a word that starts with a tilde or a slash, and runs to the
        // end of its part; what stands before it is read as any other text
        #expect(!Composer.hasKeyHint("cwd: ~/please press enter"))
        #expect(!Composer.hasKeyHint("in /Users/me/press enter · main"))
        #expect(Composer.hasKeyHint("press enter to open ~/notes"))
        #expect(!Composer.hasKeyHint("GPT-6.1-Sol high · ~/press enter · GPT-6.1-Sol"))
        #expect(!Composer.hasKeyHint("GPT-6.1-Sol high · ~/please press enter · GPT-6.1-Sol"))
        #expect(!Composer.hasKeyHint("branch fix/esc back · main"))
        #expect(Composer.hasKeyHint("abcd enter select"))
        #expect(Composer.hasKeyHint("界 enter select"))
        // not whole words
        #expect(!Composer.hasKeyHint("enter selection mode"))
        #expect(!Composer.hasKeyHint("center select"))
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

    /// The owner empties the composer in the moment before the bus's Enter, or presses Enter there and the
    /// composer on the screen is empty: the bus's Enter is dropped, and none is owed.
    @Test func anEnterTheOwnerMadeNeedlessIsDroppedAndRecorded() {
        for key in [Bus.OwnerKey.submit, .clear] {
            let rig = Rig(kind: .claude, submitDelay: 0.15)
            rig.send("first")
            rig.clock += 0.05
            rig.bus.noteOwnerInput("worker", key)
            if key == .submit { rig.io.screen = MockIO.emptied(.claude) }   // the owner's Enter sent it
            rig.fire()
            #expect(rig.enters == 0, "the text is gone")
            let enter = rig.recorded("enter")
            #expect(enter.count == 1)
            #expect(enter.first?["outcome"] as? String == "dropped")
            #expect(enter.first?["why"] as? String == (key == .submit ? "the owner pressed Enter" : "the owner emptied the composer"))
            #expect(rig.bus.info("worker")?.noComposer == false)
            #expect(rig.bus.info("worker")?.draft == false)
        }
    }

    /// The owner's Enter over the bus's text sent it when a hook reports a submission that carries that text,
    /// whatever the screen still shows. A hook that carries other text, or none, says nothing: it can be an
    /// earlier prompt's, come late.
    @Test func aSubmitHookThatCarriesThePastedTextIsEvidenceThatTheOwnersEnterSentIt() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.send("first")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] first"])
        rig.fire()
        #expect(rig.enters == 0)
        #expect(rig.recorded("enter").first?["why"] as? String == "the owner pressed Enter")
        for extra in [["prompt": "something the owner sent before"], [:]] as [[String: Any]] {
            let other = Rig(kind: .claude, submitDelay: 0.15)
            other.send("first")
            other.clock += 0.05
            other.bus.noteOwnerInput("worker", .submit)
            other.hook("UserPromptSubmit", extra)
            other.fire()
            #expect(other.recorded("enter").first?["outcome"] as? String == "owed", "\(extra)")
            other.wait(5)
            #expect(other.enters == 1, "the text is still in the composer and gets its Enter: \(extra)")
        }
        // and with no Enter of the owner's, a hook drops nothing
        let quiet = Rig(kind: .claude, submitDelay: 0.15)
        quiet.send("first")
        quiet.hook("UserPromptSubmit", ["prompt": "[from: fable] first"])
        quiet.fire()
        #expect(quiet.enters == 1)
    }

    /// Enter in a harness can accept a completion and leave the text where it is. With no evidence that the
    /// owner's Enter sent the bus's text, the bus's own Enter stays owed and goes out once the owner is
    /// quiet; and since theirs did not send it, the pane keeps its draft hold until a hook reports the
    /// submission, so nothing more is typed onto text that may still be there.
    @Test func anOwnersEnterThatSentNothingLeavesTheBussEnterOwedAndTheDraftHoldOn() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.send("first")
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .submit)   // the pane still shows the pasted text
        rig.fire()
        #expect(rig.enters == 0)
        #expect(rig.recorded("enter").last?["outcome"] as? String == "owed")
        rig.wait(4)
        #expect(rig.enters == 1, "pressed once the owner had been quiet")
        #expect(rig.bus.info("worker")?.draft == true)
        rig.send("second")
        rig.wait(10)
        #expect(!rig.io.typed.contains("second"))
        #expect(rig.bus.info("worker")?.queued == 1)
        rig.hook("UserPromptSubmit")
        rig.wait(2)
        #expect(rig.io.typed.contains("second"), "the hook reported the submission")
    }

    /// The bus's Enter is owed because a dialog opened, and the owner answers the dialog with Enter. That
    /// Enter went to the dialog; the bus's text is still in the composer and still gets its Enter. (Before,
    /// the owner's Enter dropped it, and the text stayed in the composer for good.)
    @Test func anOwnersEnterThatAnsweredADialogDoesNotDropTheBussEnter() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = ComposerShownTests.claude("❯")
        rig.send("status?")
        rig.io.screen = ComposerShownTests.claudePermission(cursorOn: 1)
        rig.fire()
        #expect(rig.enters == 0)
        rig.clock += 1
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = ComposerShownTests.claude("❯ [from: fable] status?")
        rig.wait(5)
        #expect(rig.enters == 1)
        #expect(rig.bus.info("worker")?.noComposer == false)
    }

    /// The way back for an owed Enter is only for a footer that changed in place and shows no sign of a
    /// dialog: a row with a number, a frame or a key hint in the place of an old row is never taken for the
    /// footer, however long it stays.
    @Test func aDialogSignInTheFootersPlaceNeverBecomesTheFooter() {
        for row in ["  1. Yes", "  ╭──────────╮", "  enter select · esc back"] {
            let rig = Rig(kind: .claude, submitDelay: 0.15)
            rig.io.screen = D102314ReviewTests.claude("❯", "  ⏵⏵ bypass permissions on · 1 shell")
            rig.send("status?")
            rig.io.screen = D102314ReviewTests.claude("❯ [from: fable] status?", row)
            rig.fire()
            rig.wait(30)
            #expect(rig.enters == 0, "\(row)")
            #expect(rig.bus.info("worker")?.noComposer == true, "\(row)")
        }
    }

    /// The footer must have read the same for the owner-quiet interval: one that keeps changing is not
    /// taken, and the Enter goes out once it has stood still.
    @Test func aFooterThatKeepsChangingIsNotTakenUntilItStandsStill() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = D102314ReviewTests.claude("❯", "  ⏵⏵ bypass permissions on · 1 shell")
        rig.send("status?")
        for words in ["two shells", "three shells", "four shells", "five shells", "six shells", "seven shells"] {
            rig.io.screen = D102314ReviewTests.claude("❯ [from: fable] status?", "  ⏵⏵ bypass permissions on · " + words)
            if rig.pending.isEmpty { rig.wait(1) } else { rig.fire() }
            rig.wait(1)
        }
        #expect(rig.enters == 0, "it changed every two seconds")
        rig.wait(5)
        #expect(rig.enters == 1, "it stood still for the owner-quiet interval")
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

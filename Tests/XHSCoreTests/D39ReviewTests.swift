import Foundation
import Testing
@testable import XHSCore

/// D39: an outside read of Dojo at 9e022af (Antigravity on Gemini 4 Hydrogen), finding by finding. Each test
/// here is the finding's sequence as it was written, run against the bus; a finding that does not happen
/// is said so on D39 with its reason.
@MainActor @Suite struct D39ReviewTests {
    typealias Rig = PromptHookLostTests.Rig

    static func claude(_ composer: String) -> String { ComposerShownTests.claude(composer) }

    // MARK: P1 A. A late submit hook after the owner's completion Enter

    /// The bus typed M1 into a running Claude Code, which queues it. The owner types a draft, M2 waits behind
    /// it, and the owner's Enter accepts a completion ("@bu" to "@build/"): the draft is still unsent. Then
    /// Claude Code takes M1 from its queue and reports it. The hook names M1, the bus's own text, and the
    /// draft is still in the composer: nothing may be typed onto it.
    @Test func aQueuedMessagesHookAfterACompletionEnterLeavesTheDraftHeld() {
        let rig = Rig(kind: .claude)
        rig.hook("UserPromptSubmit")
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.send("check status")
        #expect(rig.io.typed == "[from: fable] check status\r")
        rig.io.screen = Self.claude("❯\u{a0}rm -rf @bu")
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("also check tests")
        rig.bus.noteOwnerInput("worker", .submit)
        rig.io.screen = Self.claude("❯\u{a0}rm -rf @build/")
        rig.hook("UserPromptSubmit", ["prompt": "[from: fable] check status"])
        rig.wait(10)
        #expect(!rig.io.typed.contains("also check tests"), "typed onto the owner's draft: \(rig.io.typed.debugDescription)")
        #expect(rig.bus.info("worker")?.draft == true)
    }

    // MARK: P1 A. shownEmpty before the buffer check, and its trimmed marks

    /// The owner's draft is in the composer; a message waits. The owner opens a pager in the alternate screen
    /// whose last rows hold an indented "  >" over a ruled line: read as an empty composer, it ended the hold,
    /// and once the owner was back in the harness the message went onto the draft.
    @Test func aPagerThatEndsInAQuoteMarkDoesNotEndTheHold() {
        let rig = Rig(kind: .claude)
        rig.io.alternate = false
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.hook("Stop")   // at its composer: the buffer it draws in is the normal one
        rig.io.screen = Self.claude("❯\u{a0}git reset --hard")
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("ping")
        rig.wait(5)
        #expect(rig.io.written.isEmpty)
        rig.io.alternate = true
        rig.io.screen = ["# notes.md", "", "Some text of the file.", "", "  >", "────────────────────────────────", "notes.md (END)"]
            .joined(separator: "\n")
        rig.wait(5)
        rig.io.alternate = false
        rig.io.screen = Self.claude("❯\u{a0}git reset --hard")
        rig.wait(5)
        #expect(!rig.io.typed.contains("ping"), "typed onto the owner's draft: \(rig.io.typed.debugDescription)")
        #expect(rig.bus.info("worker")?.draft == true)
    }

    /// A Codex draft that starts with two new lines: the composer's first row is the mark alone, and an empty
    /// row follows, which read as an empty composer; the draft's text below read as Codex's footer.
    @Test func aCodexDraftThatStartsWithEmptyRowsIsNotAnEmptyComposer() {
        let screen = ComposerShownTests.codex("›\n\n  rm -rf build")
        #expect(!Composer.shownEmpty(kind: .codex, screen: screen), "\(screen)")
        let rig = Rig(kind: .codex)
        rig.io.screen = screen
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("ping")
        rig.wait(10)
        #expect(!rig.io.typed.contains("ping"), "typed onto the owner's draft: \(rig.io.typed.debugDescription)")
    }

    /// The same in Claude Code and agy: a draft that starts with a new line has the mark alone in its first
    /// row and an empty row under it, where an empty composer has its closing ruled line.
    @Test func aDraftThatStartsWithANewLineIsNotAnEmptyComposer() {
        let rule = String(repeating: "─", count: 60)
        for (kind, mark) in [(HarnessKind.claude, "❯\u{a0}"), (.agy, ">")] {
            let screen = [rule, mark, "", "  rm -rf build", rule, "  status"].joined(separator: "\n")
            #expect(!Composer.shownEmpty(kind: kind, screen: screen), "\(kind)")
            // and a row that only starts with the mark after blanks is not the composer's
            #expect(!Composer.shownEmpty(kind: kind, screen: ["text", "  " + mark, rule].joined(separator: "\n")), "\(kind)")
        }
    }

    // MARK: P2 B. The owner erases the bus's paste

    /// The bus pasted "hi"; the owner erased it with Backspace before the Enter: the composer is empty, the
    /// Enter is owed for text that is gone. Every later message waited for good.
    @Test func aPasteTheOwnerErasedHoldsNoLaterMessage() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.send("hi")
        rig.clock += 0.05
        for _ in 0..<16 { rig.bus.noteOwnerInput("worker", .other) }
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.fire()
        #expect(rig.enters == 0)
        rig.send("hello")
        rig.wait(30)
        rig.fire()
        #expect(rig.io.typed.contains("[from: fable] hello"), "\(rig.io.typed.debugDescription)")
    }

    // MARK: P2 D/E. The state the bus sets when it types

    /// The bus pasted into an idle pane and the owner typed right after it: the Enter is dropped, no turn
    /// started. The pane said running, with no record of the change, until the screen had been still for 15
    /// seconds.
    @Test func aDroppedEnterLeavesThePaneAsItWasAndEveryChangeIsRecorded() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.hook("Stop")
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.send("hi")
        if rig.bus.info("worker")?.state == .running {
            #expect(rig.recorded("pane-state").contains { $0["state"] as? String == "running" && $0["was"] as? String == "idle" },
                    "the change to running is in the record")
        }
        rig.clock += 0.05
        rig.bus.noteOwnerInput("worker", .text)
        rig.fire()
        #expect(rig.recorded("enter").last?["outcome"] as? String == "dropped")
        #expect(rig.bus.info("worker")?.state == .idle, "no turn started")
    }

    // MARK: P2 C. Redaction

    /// The outside route's token, on a screen or in a message, leaves the bus as it is.
    @Test func theOutsideTokenIsRedactedLikeAPanesToken() {
        let bus = Bus()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("d39-outside-\(UUID().uuidString)")
        bus.record = BusRecord(directory: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = "outside-" + UUID().uuidString
        bus.outsideToken = outside
        let io = MockIO()
        let reader = bus.add(name: "reader", kind: .claude, io: MockIO())
        _ = bus.add(name: "target", kind: .claude, io: io)
        io.screen = "$ cat ~/.dojo/outside-token\n" + outside + "\n"
        let text = json(bus.handle(path: "/read", token: reader, body: body(["pane": "target", "lines": 40])).body)["text"] as? String ?? ""
        #expect(!text.contains(outside), "\(text)")
        _ = bus.handle(path: "/send", token: reader, body: body(["pane": "target", "text": "the token is " + outside]))
        let lines = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).flatMap {
            ((try? String(contentsOf: $0, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        #expect(!lines.contains { $0.contains(outside) }, "the record keeps it")
    }

    /// Secrets of the shapes that are not fixed-prefix keys, wrapped at a narrow pane's edge: each row alone
    /// does not show the whole shape, and its parts left as they were.
    @Test func aWrappedSecretOfAnyShapeIsRedacted() {
        let bus = Bus()
        let io = MockIO()
        let reader = bus.add(name: "reader", kind: .claude, io: MockIO())
        _ = bus.add(name: "target", kind: .claude, io: io)
        io.columns = 40
        func read() -> String {
            json(bus.handle(path: "/read", token: reader, body: body(["pane": "target", "lines": 40])).body)["text"] as? String ?? ""
        }
        // each first row is the pane's whole width: the terminal wrapped it there
        let cases: [(row1: String, row2: String, secrets: [String])] = [
            ("$ echo postgres://alice:longsecretvalue1", "2@db.internal:5432/app", ["longsecretvalue1"]),
            ("$ curl -H 'Authorization: Bearer abcdefg", "hijklmnop0123456789' https://x", ["abcdefg", "hijklmnop0123456789"]),
            ("$ export SERVICE_API_KEY=abcdefghijklmno", "pqrstuvwxyz0123456789", ["pqrstuvwxyz0123456789"]),
            ("$ curl -u alice:abcdefgh https://x.examp", "le.com -u bob:ijklmnopqrstuvw0123456789", ["ijklmnopqrstuvw0123456789"]),
            ("$ curl https://x.example.com -u bob:ijkl", "mnopqrstuvw0123456789", ["mnopqrstuvw0123456789"]),
        ]
        for (row1, row2, secrets) in cases {
            #expect(row1.count == 40, "\(row1)")
            io.screen = row1 + "\n" + row2 + "\n"
            let text = read()
            for secret in secrets { #expect(!text.contains(secret), "\(text)") }
        }
    }

    // MARK: D41. A message taller than Claude Code's composer

    /// Live on 2026-11-17: a 279-character message sat in a Claude pane's composer, its Enter owed ("no
    /// composer on the screen"). Claude Code caps its composer's height: the top ruled line says how many rows
    /// are above ("─── ↑ 3 more ───"), the composer's first row with its mark is among them, and what shows
    /// is the end of the text, set in. The screen here has that shape, with a message of the same kind.
    @Test func aPasteTallerThanClaudesComposerGetsItsEnter() {
        let text = "PR 114 is with the reader for the second read (brief in ~/work/d114-brief.txt, includes make smoke from "
            + "its own pane at 28809d5a). Hold the branch still until its findings arrive; I will pass them to you. Do "
            + "not start D39 fixes on this branch."
        let rule = String(repeating: "─", count: 63)
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = [
            "✻ Churned for 41m 40s · done 12:19 AM", "", rule, "❯\u{a0}", rule, "  Usage: 5h n/a, resets at n/a · week 99% left",
        ].joined(separator: "\n")
        rig.send(text)
        rig.io.screen = [
            "✻ Churned for 41m 40s · done 12:19 AM", "",
            "─── ↑ 3 more " + String(repeating: "─", count: 50),
            "  includes make smoke from its own pane at 28809d5a). Hold",
            "  the branch still until its findings arrive; I will pass",
            "  them to you. Do not start D39 fixes on this branch.",
            rule, "  Usage: 5h n/a, resets at n/a · week 99% left",
        ].joined(separator: "\n")
        rig.fire()
        #expect(rig.enters == 1, "\(rig.recorded("enter"))")
        #expect(rig.recorded("enter").last?["outcome"] as? String == "sent")
    }

    // MARK: P3 E. A pane closed while its Enter is on its way

    /// The pane was closed between the paste and its Enter: nothing is written to it after its close, and
    /// the record has no Enter after the close.
    @Test func aClosedPaneGetsNoEnter() {
        let rig = Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.claude("❯\u{a0}")
        rig.hook("Stop")
        // the worker's own message waits in fable's queue (fable has a draft): that queue keeps the worker
        let fable = rig.bus.add(name: "other", kind: .claude, io: MockIO())
        _ = fable
        rig.bus.noteOwnerInput("other", .text)
        _ = rig.bus.handle(path: "/send", token: rig.target, body: body(["pane": "other", "text": "from the worker"]))
        rig.send("hi")
        rig.io.screen = Self.claude("❯\u{a0}[from: fable] hi")
        let written = rig.io.written.count
        rig.bus.remove("worker")
        rig.fire()
        #expect(rig.io.written.count == written, "written after the close: \(rig.io.typed.debugDescription)")
        #expect(rig.recorded("enter").isEmpty, "\(rig.recorded("enter"))")
    }
}

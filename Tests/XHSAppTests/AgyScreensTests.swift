import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

/// D38: agy's composer, read off agy 1.5.9 itself. The fixtures are the bytes agy wrote to a 130x45
/// pseudo-terminal on 2026-11-16, recorded whole, with the account's address, plan, folder and conversation
/// ids replaced by text of the same length. Each state is the stream up to the moment it was on the screen,
/// rendered here by a Dojo pane, so what is checked is what the bus sees in one.
@MainActor @Suite struct AgyScreensTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    struct State: Decodable {
        let stream: String
        let offset: Int
        /// The pseudo-terminal's size when it was recorded; 45 rows of 130 where none is given.
        var rows: Int?
        var cols: Int?
    }

    static let states: [String: State] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("agy-1.5.9-states.json"))
        return try! JSONDecoder().decode([String: State].self, from: data)
    }()

    /// The pane's live screen at a recorded state.
    static func lines(_ name: String) -> [String] {
        _ = NSApplication.shared
        let state = states[name]!
        let bytes = try! Data(contentsOf: fixtures.appendingPathComponent(state.stream))
        let pane = TerminalPane(name: "agy-1")
        pane.resize(cols: state.cols ?? 130, rows: state.rows ?? 45)
        pane.show(Array(bytes.prefix(state.offset)))
        return pane.liveScreen().lines
    }

    static func shownEmpty(_ lines: [String]) -> Bool { Composer.shownEmpty(kind: .agy, screen: lines.joined(separator: "\n")) }

    /// Idle, running, a message queued above the composer, the composer emptied by the owner or by an Enter.
    @Test func anEmptyComposerIsOneTheBusMayTypeInto() {
        // r5-1: agy's own default mode, Auto, writes its mode in the empty composer until the first prompt
        for name in ["1-idle", "1b-idle-after-turns", "1c-idle-end", "4-running", "6-queued",
                     "r3-1-idle", "r3-3-cleared", "r3-5-after-enter", "r3-6-answered", "r5-1-idle-auto", "r5-6-idle-after-skip",
                     "r8-1-idle-auto", "r8-3-running", "r8-4-idle-after-turn"] {
            let lines = Self.lines(name)
            #expect(Composer.look(kind: .agy, lines: lines, cursorLine: nil) != nil, "\(name)")
            #expect(Self.shownEmpty(lines), "\(name)")
        }
    }

    /// The owner's text in the composer: a composer, and not an empty one, so a draft hold stays on.
    @Test func typedTextIsAComposerThatIsNotEmpty() {
        for name in ["2-typed", "6a-typed-while-running", "r5-2-typed-auto", "r8-2-typed"] {
            let lines = Self.lines(name)
            #expect(Composer.look(kind: .agy, lines: lines, cursorLine: nil) != nil, "\(name)")
            #expect(!Self.shownEmpty(lines), "\(name)")
        }
    }

    /// A permission dialog, agy's question and its slash-command menu take the composer's place or open
    /// under it: no composer, and nothing is typed and no Enter pressed.
    /// r5-4 and r5-5: the question's write-in field, empty and with an answer typed; r6: agy's question
    /// whether to trust a folder it has not seen, in the terminal's other buffer, at startup.
    @Test func aDialogAQuestionOrAMenuIsNoComposer() {
        for name in ["5-dialog", "6b-question", "7-slash-menu", "r5-3-question", "r5-4-write-in", "r5-5-write-in-typed",
                     "r6-trust-dialog"] {
            let lines = Self.lines(name)
            print("D38 \(name):\n" + lines.filter { !$0.isEmpty }.suffix(12).joined(separator: "\n"))
            #expect(Composer.look(kind: .agy, lines: lines, cursorLine: nil) == nil, "\(name)")
            #expect(Composer.shown(kind: .agy, lines: lines, cursorLine: nil, afterPaste: true) == false, "\(name)")
            #expect(!Self.shownEmpty(lines), "\(name)")
        }
    }

    /// What the bus pasted is in the composer, as agy shows it: a long paste as its stand-in, a short one
    /// row by row, the later rows set in.
    @Test func whatTheBusPastedIsSeenInTheComposer() throws {
        let idle = try #require(Composer.look(kind: .agy, lines: Self.lines("r3-1-idle"), cursorLine: nil))
        let long = (["[from: supervisor] a long relayed message, as the bus pastes one:"]
                    + (1...20).map { "line \($0) of the message, plain words." }).joined(separator: "\n")
        let collapsed = Self.lines("r3-2-long-paste")
        let held = Composer.holding(kind: .agy, lines: collapsed, cursorLine: nil, pasted: long, before: idle)
        #expect(held?.composer == "[Pasted text #1 +21 lines]")
        // a stand-in that was there before the paste says nothing about this one
        let already = try #require(held)
        #expect(Composer.look(kind: .agy, lines: collapsed, cursorLine: nil) == nil, "a composer with a stand-in in it is not typed into")
        #expect(Composer.holding(kind: .agy, lines: collapsed, cursorLine: nil, pasted: long, before: already) == nil)

        let cleared = try #require(Composer.look(kind: .agy, lines: Self.lines("r3-3-cleared"), cursorLine: nil))
        let short = "[from: codex] a short relayed message:\n second line, set in by the bus as it sets every later line\n"
            + "third line. Reply with one word: ok"
        let shown = Self.lines("r3-4-short-paste")
        #expect(Composer.holding(kind: .agy, lines: shown, cursorLine: nil, pasted: short, before: cleared) != nil)
        #expect(Composer.holding(kind: .agy, lines: shown, cursorLine: nil, pasted: "something else", before: cleared) == nil)
        #expect(Composer.footerUnchanged(Composer.look(kind: .agy, lines: shown, cursorLine: nil)?.under ?? [],
                                         since: cleared.under, kind: .agy))
    }

    /// D38 follow-up: agy started from the pane's foot (`Launcher.agyFootStart`; these bytes begin with the
    /// 44 new lines it printed in a pty of 45 rows). A fresh pane has its composer on row 43 and its status line
    /// on the last row, as the other panes have theirs; after a turn agy draws its frame one row shorter, and
    /// it stays at the foot: the composer on row 42, its rule and the status line under it, an empty last row.
    @Test func aFreshPaneHasItsComposerAndStatusLineAtTheFoot() throws {
        let fresh = Self.lines("r8-1-idle-auto")
        #expect(fresh.count == 45)
        let composer = try #require(fresh.lastIndex { $0 == ">" || $0.hasPrefix("> ") })
        #expect(composer + 1 == 43)
        #expect(fresh[44].hasPrefix("Usage: 5h "))
        for name in ["r8-3-running", "r8-4-idle-after-turn"] {
            let lines = Self.lines(name)
            let row = try #require(lines.lastIndex { $0 == ">" || $0.hasPrefix("> ") })
            #expect(row + 1 == 42, "\(name)")
            let under = lines[(row + 1)...].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            #expect(under.count == 2, "\(name): the composer's rule and the status line, nothing more")
            #expect(under.last?.hasPrefix("Usage: 5h ") == true, "\(name)")
        }
    }

    /// Live on 2026-11-16: a relayed message of 7 lines and 1544 characters was pasted into an agy pane, and
    /// its Enter stayed owed ("no composer on the screen") until the owner pressed it. agy caps its composer
    /// at a height of its own and writes "↑ N more lines" on the composer's first row, then shows the end of
    /// the text; scrolled inside it, "↓ N more lines" on its last. Reproduced with a message of that shape in
    /// a pty of 30 rows and 100 columns. What the composer shows of the paste is a part of it, in its place.
    @Test func aPasteTallerThanTheComposerIsSeenByWhatItShows() throws {
        let message = String(decoding: try Data(contentsOf: Self.fixtures.appendingPathComponent("agy-1.5.9-long-message.txt")), as: UTF8.self)
        let before = try #require(Composer.look(kind: .agy, lines: Self.lines("r10-1-idle"), cursorLine: nil))
        let capped = Self.lines("r10-2-long-paste")
        #expect(capped.contains { $0.hasPrefix("> ↑ ") && $0.hasSuffix(" more lines") })
        #expect(Composer.holding(kind: .agy, lines: capped, cursorLine: nil, pasted: message, before: before) != nil)
        let scrolled = Self.lines("r10-3-scrolled-up")
        #expect(scrolled.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("↓ ") })
        #expect(Composer.holding(kind: .agy, lines: scrolled, cursorLine: nil, pasted: message, before: before) != nil)
        // what shows is not part of this paste, or not where it would be: not arrived
        #expect(Composer.holding(kind: .agy, lines: capped, cursorLine: nil, pasted: "[from: supervisor] another message entirely",
                                 before: before) == nil)
        let otherEnd = String(message.dropLast(60)) + " and an ending of another message."
        #expect(Composer.holding(kind: .agy, lines: capped, cursorLine: nil, pasted: otherEnd, before: before) == nil)
        // and before typing, a composer of many rows is never one to type into
        #expect(Composer.look(kind: .agy, lines: capped, cursorLine: nil) == nil)
    }

    /// Under the composer stands the pane's own status line, which starts in the first column.
    @Test func underTheComposerIsThePanesStatusLine() throws {
        let look = try #require(Composer.look(kind: .agy, lines: Self.lines("1-idle"), cursorLine: nil))
        #expect(look.composer == "")
        #expect(look.under.count == 1)
        #expect(look.under.first?.hasPrefix("Usage: 5h ") == true)
    }
}

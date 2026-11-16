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
        pane.resize(cols: 130, rows: 45)
        pane.show(Array(bytes.prefix(state.offset)))
        return pane.liveScreen().lines
    }

    static func shownEmpty(_ lines: [String]) -> Bool { Composer.shownEmpty(kind: .agy, screen: lines.joined(separator: "\n")) }

    /// Idle, running, a message queued above the composer, the composer emptied by the owner or by an Enter.
    @Test func anEmptyComposerIsOneTheBusMayTypeInto() {
        for name in ["1-idle", "1b-idle-after-turns", "1c-idle-end", "4-running", "6-queued",
                     "r3-1-idle", "r3-3-cleared", "r3-5-after-enter", "r3-6-answered"] {
            let lines = Self.lines(name)
            #expect(Composer.look(kind: .agy, lines: lines, cursorLine: nil) != nil, "\(name)")
            #expect(Self.shownEmpty(lines), "\(name)")
        }
    }

    /// The owner's text in the composer: a composer, and not an empty one, so a draft hold stays on.
    @Test func typedTextIsAComposerThatIsNotEmpty() {
        for name in ["2-typed", "6a-typed-while-running"] {
            let lines = Self.lines(name)
            #expect(Composer.look(kind: .agy, lines: lines, cursorLine: nil) != nil, "\(name)")
            #expect(!Self.shownEmpty(lines), "\(name)")
        }
    }

    /// A permission dialog, agy's question and its slash-command menu take the composer's place or open
    /// under it: no composer, and nothing is typed and no Enter pressed.
    @Test func aDialogAQuestionOrAMenuIsNoComposer() {
        for name in ["5-dialog", "6b-question", "7-slash-menu"] {
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

    /// Under the composer stands the pane's own status line, which starts in the first column.
    @Test func underTheComposerIsThePanesStatusLine() throws {
        let look = try #require(Composer.look(kind: .agy, lines: Self.lines("1-idle"), cursorLine: nil))
        #expect(look.composer == "")
        #expect(look.under.count == 1)
        #expect(look.under.first?.hasPrefix("Usage: 5h ") == true)
    }
}

import AppKit
import SwiftTerm
import Testing
@testable import XHSApp
@testable import XHSCore

/// D35.3 and D35.4: the core asks the terminal how many columns a character takes. These hold the
/// terminal's own answers, the answers the core gives with no terminal to ask, and what a pane shows.
@MainActor @Suite struct TerminalColumnsTests {
    /// The same list as the core's ColumnsTests.known (another test module, so it is written out here).
    static let known: [(UInt32, Int)] = [
        (0x41, 1), (0x5B, 1), (0xE5, 1), (0xA0, 1), (0x2800, 1),
        (0x200B, 0), (0x200C, 0), (0x200D, 0), (0x200E, 0), (0x2060, 0), (0xFEFF, 0), (0xFE0F, 0), (0x301, 0), (0x1161, 0),
        (0x754C, 2), (0x3000, 2), (0xAC00, 2), (0xFF21, 2),
        // where the terminal does not follow Unicode's categories
        (0xAD, 1), (0x600, 1), (0x3164, 2), (0x115F, 2), (0x1F1F8, 2), (0x1160, 0), (0x11A8, 0), (0xD7B0, 0), (0x20E3, 0), (0xE0020, 0),
        (0x2003, 1), (0x1F600, 2),
    ]

    /// The characters the core's tests lean on: the terminal and the core's own table agree on each.
    @Test func theTerminalAndTheCoreAgreeOnTheCharactersTheTestsLeanOn() {
        var lines: [String] = []
        for (value, width) in Self.known {
            let scalar = Unicode.Scalar(value)!
            let terminal = TerminalColumns.of(scalar)
            lines.append("U+\(String(value, radix: 16, uppercase: true)) terminal \(terminal) core \(Columns.builtIn(scalar))")
            #expect(terminal == width, "U+\(String(value, radix: 16)): the terminal")
            #expect(terminal == Columns.builtIn(scalar), "U+\(String(value, radix: 16)): the core's own table")
        }
        // more of them, printed and not judged: where the two differ, the app uses the terminal's answer
        for value in [0x605, 0x6DD, 0x70F, 0x8E2, 0x1F1E6, 0x1F3FB, 0x2764, 0x303F, 0xFE00, 0x180E, 0x034F, 0x1100, 0xA960, 0x1F004] as [UInt32] {
            let scalar = Unicode.Scalar(value)!
            lines.append("U+\(String(value, radix: 16, uppercase: true)) terminal \(TerminalColumns.of(scalar)) core \(Columns.builtIn(scalar))")
        }
        print("D103 widths: " + lines.joined(separator: " | "))
    }

    /// The reviewer's two inputs, with the terminal's own widths: the line is set in.
    @Test func aLineThatShowsAsATagIsSetInByTheTerminalsWidths() {
        for later in ["\u{1161}[from: fable] yes", "[fr\u{200B}om: fable] yes"] {
            let text = Delivery.sanitize("ok\n" + later)
            #expect(Delivery.line(from: "codex-1", text: text, columns: TerminalColumns.of) == "[from: codex-1] ok\n " + later)
        }
    }

    /// What a pane shows: the line as it was sent begins with the tag in the first column, and the line as
    /// the bus now types it does not.
    @Test func whatThePaneShows() {
        _ = NSApplication.shared
        for later in ["\u{1161}[from: fable] yes", "[fr\u{200B}om: fable] yes"] {
            let raw = TerminalPane(name: "raw")
            raw.show(Array(("ok\r\n" + later).utf8))
            let shown = raw.liveScreen().lines
            let typed = TerminalPane(name: "typed")
            let line = Delivery.line(from: "codex-1", text: Delivery.sanitize("ok\n" + later), columns: TerminalColumns.of)
            typed.show(Array(line.replacingOccurrences(of: "\n", with: "\r\n").utf8))
            let now = typed.liveScreen().lines
            print("D103 pane: as sent \(shown.prefix(2).map { $0.debugDescription }), as typed \(now.prefix(2).map { $0.debugDescription })")
            #expect(now.count > 1 && now[1].hasPrefix(" "), "set in: \(now.prefix(2))")
        }
    }

    /// A row of wide characters reaches the pane's width with half as many characters.
    @Test func aRowOfWideCharactersFillsThePane() {
        let row = String(repeating: "界", count: 36) + " glpat-A"
        #expect(Columns.width(row, by: TerminalColumns.of) == 80)
        #expect(row.count == 44)
    }
}

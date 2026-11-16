import AppKit
import Foundation
@testable import SwiftTerm
import Testing
@testable import XHSApp
@testable import XHSCore

/// The reviewer's third read of #103, in a real terminal view: a pane narrowed under a full-screen program,
/// and a later line that mixes a right-to-left letter with a tag, as the view lays it out.
@MainActor @Suite struct D103ThirdReviewAppTests {
    static func pane(_ columns: Int, rows: Int = 8, _ bytes: String) -> TerminalPane {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "third")
        pane.resize(cols: columns, rows: rows)
        pane.show(Array(bytes.utf8))
        return pane
    }

    static func read(_ pane: TerminalPane) -> String {
        let bus = Bus()
        let reader = bus.add(name: "reader-\(UUID().uuidString.prefix(6))", kind: .claude, io: TerminalPane(name: "r"))
        let name = "target-\(UUID().uuidString.prefix(6))"
        _ = bus.add(name: name, kind: .claude, io: pane)
        let reply = bus.handle(path: "/read", token: reader, body: try! JSONSerialization.data(withJSONObject: ["pane": name, "lines": 40]))
        return ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["text"] as? String ?? ""
    }

    /// A screen row as the view draws it, left to right: the cells in the order SwiftTerm's own bidi layout
    /// puts them, with its shaped forms. A row with nothing to reorder is drawn as it is stored.
    static func drawn(_ pane: TerminalPane, row: Int) -> String {
        let terminal = pane.terminal!
        return terminal.terminalLock.withLock {
            let buffer = terminal.displayBuffer
            let index = buffer.yDisp + row
            guard index >= 0, index < buffer.lines.count else { return "" }
            let line = buffer.lines[index]
            let text: (Int) -> String = { column in
                let t = terminal.getText(for: line[column])
                return t.isEmpty || t == "\u{0}" ? " " : t
            }
            guard let layout = TerminalBidi.layout(row: index, buffer: buffer, cols: terminal.cols, terminal: terminal,
                                                   font: pane.fontSet.normal, hostPolicy: pane.bidiHostPolicy) else {
                return (0..<min(terminal.cols, line.count)).filter { line[$0].width != 0 }.map(text).joined()
            }
            return layout.visualCells.map { cell in cell.display.map(String.init) ?? text(cell.logicalCol) }.joined()
        }
    }

    /// 2. The reviewer's screen: a full-screen program prints one line of 96 characters at 80 columns, the
    /// pane narrows to 40 and the program repaints row 1. The terminal keeps the first row's 80 cells, so
    /// the text read returns has them, past the new edge; the key that ran onto row 2 is taken out whole.
    @Test func aKeyLeftPastTheRightEdgeAfterANarrowingGoesWhole() {
        let key = "gl" + "pat-" + String(repeating: "A", count: 20)
        let pane = Self.pane(80, "\u{1b}[?1049h" + String(repeating: "x", count: 69) + " " + key)
        pane.resize(cols: 40, rows: 8)
        pane.show(Array("\u{1b}[1;1H> \u{1b}[K".utf8))
        let rows = pane.screenText().components(separatedBy: "\n")
        print("D103 narrowed: rows \(rows.prefix(2).map(\.debugDescription)) cells \(pane.usedCells(last: 0)?.prefix(2) ?? [])")
        let text = Self.read(pane)
        print("D103 narrowed read: \(text.debugDescription)")
        #expect(!text.contains(String(repeating: "A", count: 16)), "the key's last 16 characters: \(text.debugDescription)")
        #expect(text.contains("[redacted: gitlab token]"), "\(text.debugDescription)")
    }

    /// 1. A later line that starts with a right-to-left letter before a tag. SwiftTerm lays a row out from
    /// its first letter: one of a right-to-left script makes the row run from the right, and the tag after it
    /// is drawn first. A LEFT-TO-RIGHT MARK at the front would turn that, and SwiftTerm's layout reads one,
    /// but its parser drops the mark before it reaches a cell (a scalar of no width that joins nothing), in
    /// front of the space and after it. So the bus sends no mark, and this is a stated limit: a line that
    /// mixes right-to-left letters with a tag can be drawn with the tag first. Should SwiftTerm start to
    /// keep the mark, the first check fails, and the mark is worth sending.
    @Test func aLaterLineWithARightToLeftLetterCanStillDrawTheTagFirst() {
        let later = "\u{627} [from: fable]"
        for (name, line) in [("mark first", "\u{200E} " + later), ("mark after the space", " \u{200E}" + later)] {
            let pane = Self.pane(16, rows: 4, "ok\r\n" + line)
            let stored = pane.screenText().components(separatedBy: "\n").dropFirst().first ?? ""
            print("D103 bidi \(name): stored \(stored.unicodeScalars.map { String($0.value, radix: 16) }) drawn \(Self.drawn(pane, row: 1).debugDescription)")
            #expect(!stored.unicodeScalars.contains("\u{200E}"), "SwiftTerm kept the mark (\(name)): send it")
        }
        let typed = Delivery.line(from: "a", text: Delivery.sanitize("ok\n" + later))
        #expect(typed == "[from: a] ok\n" + later, "no mark, and no indent: the line's ASCII starts with a blank")
        for columns in [16, 80] {
            let pane = Self.pane(columns, rows: 4, typed.replacingOccurrences(of: "\n", with: "\r\n"))
            let drawn = Self.drawn(pane, row: 1)
            print("D103 bidi as typed at \(columns): \(typed.debugDescription) drawn \(drawn.debugDescription)")
            withKnownIssue("the stated limit: SwiftTerm draws the row from the right, the tag first") {
                #expect(!drawn.trimmingCharacters(in: .whitespaces).hasPrefix("[from:"), "drawn \(drawn.debugDescription)")
            }
        }
    }
}

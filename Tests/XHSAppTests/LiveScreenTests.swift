import AppKit
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

/// D35.1: the bus reads a pane's live screen in one step just before it types: the terminal's own lines,
/// with a row it wrapped joined to the one it continues, and the line the cursor is on.
@Suite @MainActor struct LiveScreenTests {
    @Test func aWrappedRowIsJoinedAndTheCursorsLineIsKnown() {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "p")
        let columns = pane.terminalDimensions.cols
        let long = String(repeating: "a", count: columns - 3) + " enter select"   // runs over the right edge
        pane.show(Array(("first\r\n" + long + "\r\n› composer").utf8))
        let screen = pane.liveScreen()
        let lines = screen.lines.prefix { !$0.isEmpty }
        #expect(lines.count == 3, "three lines, not the four rows they fill: \(Array(lines))")
        #expect(lines.first == "first")
        #expect(lines.dropFirst().first == long, "the words either side of the edge are one line again")
        #expect(lines.last == "› composer")
        #expect(screen.cursorLine == 2, "the cursor is after the last thing written")
        // moved up to the first row
        pane.show(Array("\u{1b}[1;1H".utf8))
        #expect(pane.liveScreen().cursorLine == 0)
    }

    @Test func theBusReadsTheSameScreen() {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "p")
        pane.show(Array("──────────────\r\n❯ \r\n──────────────\r\n  status".utf8))
        let screen = pane.liveScreen()
        #expect(Composer.shown(kind: .claude, lines: screen.lines, cursorLine: nil) == true)
        // the cursor is on the status row here, not on the composer
        #expect(Composer.shown(kind: .claude, lines: screen.lines, cursorLine: screen.cursorLine) == false)
        pane.show(Array("\u{1b}[2;3H".utf8))
        let moved = pane.liveScreen()
        #expect(Composer.shown(kind: .claude, lines: moved.lines, cursorLine: moved.cursorLine) == true)
    }
}

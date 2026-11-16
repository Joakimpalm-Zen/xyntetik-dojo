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

    /// What the rule cannot close is the moment between the bus's look at the screen and its keystroke
    /// reaching the harness: a dialog the harness draws in that moment is not seen. This measures how long
    /// that moment can be, with a real program in a real pane: a key is written, the terminal driver echoes
    /// it, and the time until it is back on the pane's screen is one trip there and one back. It is printed,
    /// not held to a tight bound, since a busy machine stretches it.
    @Test func aKeystrokeIsBackOnTheScreenInMilliseconds() async throws {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "p")
        pane.startProcess(executable: "/bin/cat", args: [], environment: ["TERM=xterm-256color"], execName: nil, currentDirectory: nil)
        defer { pane.terminate() }
        try await Task.sleep(nanoseconds: 300_000_000)
        var times: [Double] = []
        for round in 0..<20 {
            let key = "k\(round)z"
            let written = Date()
            pane.write(Array(key.utf8))
            while !pane.liveScreen().lines.joined().contains(key), Date().timeIntervalSince(written) < 5 {
                try await Task.sleep(nanoseconds: 200_000)
            }
            times.append(Date().timeIntervalSince(written) * 1000)
        }
        times.sort()
        let median = times[times.count / 2], slowest = times[times.count - 1]
        print(String(format: "D35.1 window: a key written to a pane was back on its screen after %.1f ms (median of 20, slowest %.1f ms)", median, slowest))
        #expect(median < 1000, "the pane's own echo took \(median) ms")
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

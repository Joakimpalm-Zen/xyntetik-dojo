import AppKit
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

/// D37: a pane that was made narrower. What a harness drew beyond the new right edge stays in the pane's
/// text, and is not on its live screen, which is what the bus now goes by when it looks for an empty composer.
@MainActor @Suite struct NarrowedPaneTests {
    @Test func whatAWiderPaneHadBeyondTheEdgeIsNotOnTheLiveScreen() {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "narrowed")
        pane.resize(cols: 141, rows: 8)
        // a harness in the alternate buffer, as Claude Code is: its composer, and a hint at the right edge of
        // the same row
        // between its ruled lines, as Claude Code draws it (an empty composer is read in its frame, D39)
        let rule = String(repeating: "─", count: 120)
        pane.show(Array("\u{1b}[?1049h\u{1b}[2;1H\(rule)\u{1b}[3;1H❯\u{a0}\u{1b}[3;121Hnew message (click) ↓\u{1b}[4;1H\(rule)".utf8))
        pane.resize(cols: 129, rows: 8)
        // the harness draws its composer again for the new width, and clears to the end of the row
        pane.show(Array("\u{1b}[3;1H❯\u{a0}\u{1b}[K".utf8))
        let text = pane.screenText().components(separatedBy: "\n")
        let live = pane.liveScreen().lines
        let inText = text.first { $0.hasPrefix("❯") } ?? ""
        let onScreen = live.first { $0.hasPrefix("❯") } ?? ""
        print("D37 the composer's row in the pane's text: \(inText.count) characters, ends \(String(inText.suffix(14)).debugDescription); on the live screen: \(onScreen.debugDescription)")
        #expect(Composer.shownEmpty(kind: .claude, screen: live.joined(separator: "\n")), "an empty composer, as the pane shows it")
        #expect(onScreen.count <= 129)
        // what the bus read before: this pins the cause, and says so if the terminal ever stops keeping it
        #expect(inText.count > 129, "the pane's text no longer keeps what was beyond the edge: \(inText.debugDescription)")
    }
}

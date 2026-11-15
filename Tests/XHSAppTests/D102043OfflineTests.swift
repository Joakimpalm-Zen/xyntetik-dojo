import AppKit
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

// Memory-only terminal instances; no process, PTY, or window is opened.
@MainActor @Suite struct D102043OfflineTests {
    @Test func anExplicitSpaceAtTheWrapBoundaryIsPreserved() {
        _=NSApplication.shared
        let pane=TerminalPane(name:"offline")
        pane.resize(cols:12,rows:12)
        pane.show(Array("\r\n›\r\n\r\n  abcd enter select".utf8))
        let screen=pane.liveScreen()
        print("043 wrapped space",screen.lines)
        #expect(screen.lines.contains("  abcd enter select"))
        #expect(Composer.shown(kind:.codex,lines:screen.lines,cursorLine:nil) == false)
    }
    @Test func reenteringTheAlternateBufferDoesNotToggleToTheOtherOne() {
        _=NSApplication.shared
        let pane=TerminalPane(name:"offline")
        pane.show(Array("\u{1b}[?1049h\r\n› harness\r\n\r\n  status".utf8))
        #expect(pane.liveScreen().alternate == true)
        pane.show(Array("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\r\n› editor file\r\n\r\n  status".utf8))
        #expect(pane.liveScreen().alternate == true)
        // It is still the same buffer; this flag cannot identify its owner.
        #expect(Composer.look(kind:.codex,lines:pane.liveScreen().lines,cursorLine:nil) != nil)
    }
}

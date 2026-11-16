import AppKit
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

// Emulator-only tests. No window, PTY, child process, or writes to a process.
@MainActor @Suite struct D102OfflineReviewTests {
    @Test func joiningAWideWrappedHintDoesNotInsertSpacesInsideItsWords() {
        _=NSApplication.shared
        let pane=TerminalPane(name:"offline")
        pane.resize(cols:12,rows:12)
        pane.show(Array("\r\n›\r\n\r\n  界 enter select".utf8))
        let snap=pane.terminalContentSnapshot(region:.history(maximumScrollbackRows:0))!
        print("D102 physical rows",snap.rows.map { ($0.text,$0.isWrapped) })
        let live=pane.liveScreen()
        print("D102 joined rows",live.lines)
        #expect(live.lines.contains("  界 enter select"))
        #expect(Composer.shown(kind:.codex,lines:live.lines,cursorLine:nil) == false)
    }

    @Test func alternateScreenFileIsNotTheHarnessComposer() {
        _=NSApplication.shared
        let pane=TerminalPane(name:"offline")
        pane.show(Array("\u{1b}[?1049h\r\n› file contents\r\n\r\n  status".utf8))
        #expect(pane.terminalInputStateSnapshot()?.isAlternateBuffer == true)
        let screen=pane.liveScreen()
        #expect(screen.alternate == true)
        // Changed from the reviewer's line, which asked the rule to say no to any alternate screen: both
        // harnesses draw themselves there in this app (a pane's read gives back the screen's rows and no
        // more after hours of output), so the rule cannot. The bus says no: it knows the harness's buffer
        // from the last hook that had the harness at its composer, and this is the other one.
        let bus=Bus()
        let token=bus.add(name:"offline",kind:.codex,io:pane)
        let sender=bus.add(name:"fable",kind:.claude,io:TerminalPane(name:"sender"))
        func call(_ path:String,_ token:String,_ fields:[String:Any]) -> [String:Any] {
            let reply=bus.handle(path:path,token:token,body:try! JSONSerialization.data(withJSONObject:fields))
            return (try? JSONSerialization.jsonObject(with:reply.body)) as? [String:Any] ?? [:]
        }
        // the harness at its composer, in the buffer it draws itself in: only then is the buffer learned
        pane.show(Array("\u{1b}[?1049l\u{1b}[2J\u{1b}[H\r\n› Ask Codex to do anything\r\n\r\n  status".utf8))
        _=call("/hook",token,["hook_event_name":"Stop"])
        pane.show(Array("\u{1b}[?1049h\r\n› file contents\r\n\r\n  status".utf8))
        #expect(Composer.shown(kind:.codex,lines:pane.liveScreen().lines,cursorLine:nil) == true,"by its rows alone this is a composer")
        #expect(call("/send",sender,["pane":"offline","text":"status?"])["delivered"] as? Bool == false,"a pager/editor can display this file while the harness is not taking input")
        #expect(bus.info("offline")?.noComposer == true)
    }

    /// One column left open before a wide character is where that character did not fit: no blank belongs
    /// between the two rows.
    @Test func aWideCharacterThatDidNotFitIsJoinedWithoutABlank() {
        _=NSApplication.shared
        let pane=TerminalPane(name:"offline")
        pane.resize(cols:12,rows:12)
        pane.show(Array("aaaaaaaaaaa界b".utf8))
        let snap=pane.terminalContentSnapshot(region:.history(maximumScrollbackRows:0))!
        print("D102 wide rows",snap.rows.prefix(2).map { ($0.text,$0.isWrapped) })
        #expect(pane.liveScreen().lines.first == "aaaaaaaaaaa界b")
    }
}

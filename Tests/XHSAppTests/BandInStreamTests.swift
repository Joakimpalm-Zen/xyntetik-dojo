import AppKit
import SwiftTerm
import Testing
@testable import XHSApp

/// Colour must never cost output: a focus change may land anywhere in a harness's stream, and the band's colour
/// goes through that same stream.
@Suite @MainActor struct BandInStreamTests {
    private static let streams = [
        "before \u{1b}]0;räksmörgås 👩‍💻\u{7}after",
        "before \u{1b}]2;a title\u{1b}\\after",
        "\u{1b}]7;file:///tmp/å\u{7}after",
        "\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7} after",
        "\u{1b}P1$r0m\u{1b}\\after",
        "\u{1b}P+q544e\u{1b}\\after",
        "\u{1b}_private\u{1b}\\after",
        "\u{1b}Xstring\u{1b}\\after",
        "\u{1b}^message\u{1b}\\after",
        "\u{1b}[1;31mred\u{1b}[0m \u{1b}[2;5Hmoved \u{1b}[48;5;255mband\u{1b}[0m",
        "\u{1b}(0qqq\u{1b}(B after",
        "räksmörgås 👩‍💻 e\u{301} 日本語 after",
        "\u{1b}[?2026hsynced\u{1b}[?2026l after",
    ]

    /// Records what the terminal reports, which the app's own delegate drops.
    private final class Reports: TerminalViewDelegate {
        var title = ""
        var directory = ""
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) { self.title = title }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { self.directory = directory ?? "" }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
    }

    /// A pane that has had `chunks`, with `between` run after the first. What a harness or the owner can see of
    /// it: the screen, the title and the folder.
    private func run(_ chunks: [[UInt8]], between: (TerminalPane) -> Void = { _ in }) async -> (seen: [String], pane: TerminalPane) {
        let pane = TerminalPane(name: "p")
        let reports = Reports()
        pane.terminalDelegate = reports
        for (i, chunk) in chunks.enumerated() {
            pane.show(chunk)
            if i == 0 { between(pane) }
        }
        // SwiftTerm reports a title on the next turn of the main queue.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
        return ([pane.visibleText(), reports.title, reports.directory], pane)
    }

    @Test func aFocusChangeAtAnyByteLeavesTheStreamWhole() async {
        _ = NSApplication.shared
        for stream in BandInStreamTests.streams {
            let bytes = Array(stream.utf8)
            let wanted = await run([bytes]).seen
            for cut in 0...bytes.count {
                let split = await run([Array(bytes[..<cut]), Array(bytes[cut...])]) { $0.dimmed = true }
                #expect(split.seen == wanted, "\(stream) cut at \(cut)")
                #expect(!split.pane.bandWaiting, "\(stream) cut at \(cut)")
            }
        }
    }

    /// Broken streams too: where the parser and `ParserRest` could disagree. The same cut with no focus change
    /// is the control, so the only difference between the two is the band.
    @Test func brokenStreamsLoseNothingEither() async {
        _ = NSApplication.shared
        let pieces: [[UInt8]] = [
            [0x1B], [0x1B, 0x5B], [0x1B, 0x5D], Array("\u{1b}]0;".utf8), Array("\u{1b}P".utf8), Array("\u{1b}_".utf8), Array("\u{1b}X".utf8),
            Array("\u{1b}(".utf8), Array("\u{1b}\\".utf8), [0x07], [0x18], [0x1A], [0x90], [0x9B], [0x9C], [0x9D], [0x9E], [0x9F], [0x85],
            [0xC3], [0xE2, 0x82], [0xF0, 0x9F], Array("å".utf8), Array("abc".utf8), Array("1;3".utf8), Array("m".utf8), Array("\r\n".utf8),
        ]
        var seed: UInt64 = 0x5EED_D13
        func next(_ bound: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(bound))
        }
        for _ in 0..<60 {
            var bytes: [UInt8] = []
            for _ in 0..<(4 + next(8)) { bytes += pieces[next(pieces.count)] }
            bytes += Array("\u{7}\u{18}END".utf8)
            for cut in 0...bytes.count {
                let chunks = [Array(bytes[..<cut]), Array(bytes[cut...])]
                let control = await run(chunks).seen
                let dimmed = await run(chunks) { $0.dimmed = true }.seen
                #expect(dimmed == control, "\(bytes) cut at \(cut)")
            }
        }
    }

    @Test func aFocusChangeInsideAStringWaitsForItsEnd() async {
        _ = NSApplication.shared
        let split = await run([Array("\u{1b}]0;half".utf8), Array(" and half\u{7}".utf8)]) {
            $0.dimmed = true
            #expect($0.bandWaiting)
        }
        #expect(!split.pane.bandWaiting)
        #expect(split.seen[1] == "half and half")
    }

    @Test func aStringThatNeverEndsKeepsTheBandWaiting() {
        _ = NSApplication.shared
        let pane = TerminalPane(name: "p")
        pane.show(Array("\u{1b}Pnever ends".utf8))
        pane.dimmed = true
        pane.show(Array("still going".utf8))
        #expect(pane.bandWaiting)
    }
}

import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

/// D42: Claude Code 2.1.326's capped composer in a renamed session, read off Claude Code itself. The fixture is the
/// bytes it wrote to a 105x14 pseudo-terminal on 2026-11-17, recorded whole up to the moment shown, with the
/// folder and the plan's name replaced by text of the same length:
/// - `/rename d42-probe`, so the composer's top line carries the session's name at its right end;
/// - then a 549-character message pasted (bracketed, as the bus pastes), taller than the composer a pane of 14 rows
///   lets Claude Code show: the top line reads "─── ↑ 4 more ─── … ─── d42-probe ─".
/// Rendered here by a Dojo pane, so what is checked is what the bus sees in one.
@MainActor @Suite struct ClaudeScreensTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    /// The pane's live screen after `offset` bytes of the recording.
    static func lines(_ offset: Int) -> [String] {
        _ = NSApplication.shared
        let bytes = try! Data(contentsOf: fixtures.appendingPathComponent("claude-2.1.326-renamed-capped.bin"))
        let pane = TerminalPane(name: "claude-1")
        pane.resize(cols: 105, rows: 14)
        pane.show(Array(bytes.prefix(offset)))
        return pane.liveScreen().lines
    }

    /// The offsets of the two moments: renamed with an empty composer, and the paste in it, capped.
    static let renamed = 8639, capped = 10328

    @Test func aPasteTallerThanARenamedSessionsComposerIsSeenByItsEnd() throws {
        let message = String(decoding: try Data(contentsOf: Self.fixtures.appendingPathComponent("claude-2.1.326-renamed-capped.txt")),
                             as: UTF8.self)
        let before = try #require(Composer.look(kind: .claude, lines: Self.lines(Self.renamed), cursorLine: nil))
        #expect(before.composer == "")
        let shown = Self.lines(Self.capped)
        let top = try #require(shown.first { $0.contains("↑ 4 more") })
        #expect(top.hasPrefix("─── ↑ 4 more ") && top.hasSuffix(" d42-probe ─"), "\(top.debugDescription)")
        #expect(Composer.holding(kind: .claude, lines: shown, cursorLine: nil, pasted: message, before: before) != nil)
        // another text under the same line is not this paste
        #expect(Composer.holding(kind: .claude, lines: shown, cursorLine: nil, pasted: "[from: probe] something else entirely",
                                 before: before) == nil)
    }
}

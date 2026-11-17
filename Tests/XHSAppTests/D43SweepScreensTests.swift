import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import XHSApp
import XHSCore

/// D43: parametrised composer sweep across real Claude Code 2.1.326 and Codex 0.169.0 pty recordings
/// (`Fixtures/sweep-2026-11-17/`). Each fixture carries the stream up to the paste and the pasted text,
/// scrubbed of plan names with no personal data. Committed red-first before fixing any uncovered shapes.
@MainActor @Suite struct D43SweepScreensTests {
    static let sweepDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("sweep-2026-11-17")

    struct SweepCase: Decodable, Sendable, CustomTestStringConvertible {
        let id: String
        let harness: String
        let version: String
        let mode: String
        let cols: Int
        let rows: Int
        let renameMode: String
        let rename: String?
        let pasteKey: String
        let pasteChars: Int
        let pasteLines: Int
        let draft: String?
        let queuedBanner: Bool
        let beforeOffset: Int
        let beforePasteOffset: Int
        let afterOffset: Int
        let expectEnter: Bool

        var testDescription: String { id }

        var harnessKind: HarnessKind {
            harness == "codex" ? .codex : .claude
        }
    }

    static let cases: [SweepCase] = {
        let data = try! Data(contentsOf: sweepDir.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode([SweepCase].self, from: data)
    }()

    static func screenLines(id: String, cols: Int, rows: Int, offset: Int) -> [String] {
        _ = NSApplication.shared
        let bytes = try! Data(contentsOf: sweepDir.appendingPathComponent("\(id).bin"))
        let pane = TerminalPane(name: id)
        pane.resize(cols: cols, rows: rows)
        pane.show(Array(bytes.prefix(offset)))
        return pane.liveScreen().lines
    }

    static func footPreview(_ lines: [String]) -> String {
        lines.enumerated()
            .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(12)
            .map { String(format: "%02d: %@", $0.offset, $0.element.debugDescription) }
            .joined(separator: "\n")
    }

    @Test(arguments: D43SweepScreensTests.cases)
    func sweepRecordingMatchesComposerContract(_ entry: SweepCase) throws {
        let pasted = String(
            decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(entry.id).txt")),
            as: UTF8.self
        )
        let kind = entry.harnessKind
        let beforeIdleLines = Self.screenLines(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.beforeOffset)
        let beforeIdle = Composer.look(kind: kind, lines: beforeIdleLines, cursorLine: nil)

        if entry.expectEnter {
            let look = try #require(
                beforeIdle,
                "\(entry.id): before-paste composer not read.\nScreen:\n\(Self.footPreview(beforeIdleLines))"
            )
            let afterLines = Self.screenLines(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.afterOffset)
            let held = try #require(
                Composer.holding(kind: kind, lines: afterLines, cursorLine: nil, pasted: pasted, before: look),
                "\(entry.id): paste not seen in composer.\nBefore under: \(look.under)\nAfter screen:\n\(Self.footPreview(afterLines))"
            )
            let sameFooter = Composer.footerUnchanged(held.under, since: look.under, kind: kind)
            #expect(
                sameFooter,
                "\(entry.id): footer changed after paste.\nBefore under: \(look.under)\nAfter under:  \(held.under)\nAfter screen:\n\(Self.footPreview(afterLines))"
            )
            #expect(
                Composer.shown(kind: kind, lines: afterLines, cursorLine: nil, afterPaste: true, pasted: pasted, before: look) == true,
                "\(entry.id): Composer.shown denied Enter.\nAfter screen:\n\(Self.footPreview(afterLines))"
            )
        } else {
            let beforePasteLines = Self.screenLines(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.beforePasteOffset)
            #expect(
                !Composer.shownEmpty(kind: kind, screen: beforePasteLines.joined(separator: "\n")),
                "\(entry.id): draft screen must not read empty.\nDraft screen:\n\(Self.footPreview(beforePasteLines))"
            )
            let beforeDraft = Composer.look(kind: kind, lines: beforePasteLines, cursorLine: nil)
            let afterLines = Self.screenLines(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.afterOffset)
            if let beforeIdle {
                #expect(
                    Composer.shown(kind: kind, lines: afterLines, cursorLine: nil, afterPaste: true, pasted: pasted, before: beforeIdle) != true,
                    "\(entry.id): composer holds owner draft, Enter must NOT go out (vs idle).\nDraft screen:\n\(Self.footPreview(beforePasteLines))\nAfter screen:\n\(Self.footPreview(afterLines))"
                )
            }
            if let beforeDraft {
                #expect(
                    Composer.shown(kind: kind, lines: afterLines, cursorLine: nil, afterPaste: true, pasted: pasted, before: beforeDraft) != true,
                    "\(entry.id): composer holds owner draft, Enter must NOT go out (vs draft).\nDraft screen:\n\(Self.footPreview(beforePasteLines))\nAfter screen:\n\(Self.footPreview(afterLines))"
                )
            }
        }
    }
}

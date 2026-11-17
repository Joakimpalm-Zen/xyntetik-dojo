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

    static func liveScreen(id: String, cols: Int, rows: Int, offset: Int) -> (screen: PaneScreen, columns: Int) {
        _ = NSApplication.shared
        let bytes = try! Data(contentsOf: sweepDir.appendingPathComponent("\(id).bin"))
        let pane = TerminalPane(name: id)
        pane.resize(cols: cols, rows: rows)
        pane.show(Array(bytes.prefix(offset)))
        return (pane.liveScreen(), pane.columns)
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
        let beforeIdleScreen = Self.liveScreen(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.beforeOffset)
        let beforeIdle = Composer.look(kind: kind, lines: beforeIdleScreen.screen.lines, cursorLine: nil,
                                       alternate: beforeIdleScreen.screen.alternate, columns: beforeIdleScreen.columns)

        if entry.expectEnter {
            let look = try #require(
                beforeIdle,
                "\(entry.id): before-paste composer not read.\nScreen:\n\(Self.footPreview(beforeIdleScreen.screen.lines))"
            )
            let afterScreen = Self.liveScreen(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.afterOffset)
            let held = try #require(
                Composer.holding(kind: kind, lines: afterScreen.screen.lines, cursorLine: nil, pasted: pasted, before: look,
                                 alternate: afterScreen.screen.alternate, columns: afterScreen.columns),
                "\(entry.id): paste not seen in composer.\nBefore under: \(look.under)\nAfter screen:\n\(Self.footPreview(afterScreen.screen.lines))"
            )
            let sameFooter = Composer.footerUnchanged(held.under, since: look.under, kind: kind)
            #expect(
                sameFooter,
                "\(entry.id): footer changed after paste.\nBefore under: \(look.under)\nAfter under:  \(held.under)\nAfter screen:\n\(Self.footPreview(afterScreen.screen.lines))"
            )
            #expect(
                Composer.shown(kind: kind, lines: afterScreen.screen.lines, cursorLine: nil, afterPaste: true, pasted: pasted, before: look,
                               alternate: afterScreen.screen.alternate, columns: afterScreen.columns) == true,
                "\(entry.id): Composer.shown denied Enter.\nAfter screen:\n\(Self.footPreview(afterScreen.screen.lines))"
            )
        } else {
            let beforePasteScreen = Self.liveScreen(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.beforePasteOffset)
            #expect(
                !Composer.shownEmpty(kind: kind, screen: beforePasteScreen.screen.lines.joined(separator: "\n")),
                "\(entry.id): draft screen must not read empty.\nDraft screen:\n\(Self.footPreview(beforePasteScreen.screen.lines))"
            )
            let beforeDraft = Composer.look(kind: kind, lines: beforePasteScreen.screen.lines, cursorLine: nil,
                                            alternate: beforePasteScreen.screen.alternate, columns: beforePasteScreen.columns)
            let afterScreen = Self.liveScreen(id: entry.id, cols: entry.cols, rows: entry.rows, offset: entry.afterOffset)
            if let beforeIdle {
                let check = {
                    #expect(
                        Composer.shown(kind: kind, lines: afterScreen.screen.lines, cursorLine: nil, afterPaste: true, pasted: pasted, before: beforeIdle,
                                       alternate: afterScreen.screen.alternate, columns: afterScreen.columns) != true,
                        "\(entry.id): composer holds owner draft, Enter must NOT go out (vs idle).\nDraft screen:\n\(Self.footPreview(beforePasteScreen.screen.lines))\nAfter screen:\n\(Self.footPreview(afterScreen.screen.lines))"
                    )
                }
                if entry.id == "claude-105x14-short-draft-s300" || entry.id == "claude-105x14-short-draft-w550" {
                    withKnownIssue("\(entry.id): 5-char draft fits inside row 0's wrap slack giving identical ↑ count and tail rows as an idle paste (Bus Enter rule still blocks Enter)") {
                        check()
                    }
                } else {
                    check()
                }
            }
            if let beforeDraft {
                let check = {
                    #expect(
                        Composer.shown(kind: kind, lines: afterScreen.screen.lines, cursorLine: nil, afterPaste: true, pasted: pasted, before: beforeDraft,
                                       alternate: afterScreen.screen.alternate, columns: afterScreen.columns) != true,
                        "\(entry.id): composer holds owner draft, Enter must NOT go out (vs draft).\nDraft screen:\n\(Self.footPreview(beforePasteScreen.screen.lines))\nAfter screen:\n\(Self.footPreview(afterScreen.screen.lines))"
                    )
                }
                if entry.id == "claude-105x14-short-draft-s300" || entry.id == "claude-105x14-short-draft-w550" {
                    withKnownIssue("\(entry.id): same wrap-slack identity when called directly with beforeDraft") {
                        check()
                    }
                } else {
                    check()
                }
            }
        }
    }

    @MainActor final class RecordingPaneIO: PaneIO {
        let pane: TerminalPane
        var writes: [[UInt8]] = []

        init(name: String, cols: Int, rows: Int) {
            _ = NSApplication.shared
            pane = TerminalPane(name: name)
            pane.resize(cols: cols, rows: rows)
        }

        var pasteCount: Int { writes.filter { $0 != Delivery.enter }.count }
        var enterCount: Int { writes.filter { $0 == Delivery.enter }.count }

        func show<S: Sequence>(_ bytes: S) where S.Element == UInt8 { pane.show(Array(bytes)) }
        func write(_ bytes: [UInt8]) { writes.append(bytes) }
        func screenText() -> String { pane.screenText() }
        func visibleText() -> String { pane.visibleText() }
        func liveScreen() -> PaneScreen { pane.liveScreen() }
        func usedCells(last count: Int) -> [Int]? { pane.usedCells(last: count) }
        var columns: Int { pane.columns }
        var bracketedPasteEnabled: Bool { pane.bracketedPasteEnabled }
    }

    static func sendPayload(from pasted: String) -> String {
        pasted.hasPrefix("[from: probe] ") ? String(pasted.dropFirst("[from: probe] ".count)) : pasted
    }

    static func makeBusRig(entry: SweepCase) -> (bus: Bus, sender: String, target: String, io: RecordingPaneIO, bytes: Data, advance: (TimeInterval) -> Void, fire: () -> Void) {
        let io = RecordingPaneIO(name: "worker", cols: entry.cols, rows: entry.rows)
        let bytes = try! Data(contentsOf: sweepDir.appendingPathComponent("\(entry.id).bin"))
        let bus = Bus()
        var clock = Date(timeIntervalSince1970: 10_000)
        var pending: (() -> Void)?
        bus.now = { clock }
        bus.schedule = { _, work in pending = work }
        bus.submitDelay = 0.15
        let sender = bus.add(name: "probe", kind: .claude, io: nil)
        let target = bus.add(name: "worker", kind: entry.harnessKind, io: io)
        _ = bus.handle(path: "/hook", token: target, body: try! JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart"]))
        return (bus, sender, target, io, bytes, { dt in clock.addTimeInterval(dt) }, {
            let work = pending
            pending = nil
            work?()
        })
    }

    @Test(arguments: D43SweepScreensTests.cases)
    func sweepRecordingThroughRealBus(_ entry: SweepCase) throws {
        let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(entry.id).txt")), as: UTF8.self)
        let rig = Self.makeBusRig(entry: entry)
        let body = try JSONSerialization.data(withJSONObject: ["pane": "worker", "text": Self.sendPayload(from: pasted)])

        if entry.expectEnter {
            rig.io.show(rig.bytes.prefix(entry.beforeOffset))
            let (status, resData) = rig.bus.handle(path: "/send", token: rig.sender, body: body)
            #expect(status == 200)
            let res = try JSONSerialization.jsonObject(with: resData) as! [String: Any]
            #expect(res["delivered"] as? Bool == true, "\(entry.id): paste was held on before-screen")
            #expect(rig.io.pasteCount == 1, "\(entry.id): paste bytes missing")
            #expect(rig.io.enterCount == 0, "\(entry.id): Enter must wait for submitDelay")

            rig.io.show(rig.bytes[entry.beforeOffset..<entry.afterOffset])
            rig.fire()
            #expect(rig.io.enterCount == 1, "\(entry.id): Enter not pressed after settled paste screen")
            #expect(rig.bus.info("worker")?.noComposer == false, "\(entry.id): noComposer stayed true")
        } else {
            rig.io.show(rig.bytes.prefix(entry.beforePasteOffset))
            rig.bus.noteOwnerInput("worker", .text)
            rig.advance(4)
            let (status, resData) = rig.bus.handle(path: "/send", token: rig.sender, body: body)
            #expect(status == 200)
            let res = try JSONSerialization.jsonObject(with: resData) as! [String: Any]
            #expect(res["delivered"] as? Bool == false, "\(entry.id): draft on screen must hold queue")
            #expect(rig.io.writes.isEmpty, "\(entry.id): Bus wrote bytes over visible draft")
            #expect(rig.bus.info("worker")?.draft == true)
            #expect(rig.bus.info("worker")?.queued == 1)
        }
    }

    @Test func staleDraftEchoHoldsThroughRealBus() throws {
        for id in ["claude-105x14-short-draft-s300", "claude-105x14-short-draft-w550"] {
            let entry = try #require(Self.cases.first { $0.id == id })
            let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(entry.id).txt")), as: UTF8.self)
            let rig = Self.makeBusRig(entry: entry)
            let recDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: recDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: recDir) }
            rig.bus.record = BusRecord(directory: recDir)
            // 1. Composer starts empty; owner types "wip: ", whose echo is delayed > 3 s.
            rig.io.show(rig.bytes.prefix(entry.beforeOffset))
            rig.bus.noteOwnerInput("worker", .text)
            rig.advance(4)
            // 2. Peer message arrives while screen still shows empty; paste goes in, capped box hides head.
            let body = try JSONSerialization.data(withJSONObject: ["pane": "worker", "text": Self.sendPayload(from: pasted)])
            _ = rig.bus.handle(path: "/send", token: rig.sender, body: body)
            rig.io.show(rig.bytes[entry.beforeOffset..<entry.afterOffset])
            rig.fire()
            for _ in 0..<5 { rig.advance(1); rig.bus.tick() }
            // 3. Rule at Enter: owner typed without proof it emptied & composer head is hidden -> Enter NOT sent, owner told why.
            #expect(rig.io.enterCount == 0, "\(id): Enter must NOT be sent when owner typed and head is hidden")
            #expect(rig.bus.info("worker")?.needsOwnerEnter == true, "\(id): header must tell owner Enter is needed")
            let logText = BusRecord.files(in: recDir).compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
            #expect(logText.contains("owner typed before paste and composer head is hidden"), "\(id): record missing explanation")
            // 4. Ctrl-C clears the hold cleanly.
            rig.bus.noteOwnerInput("worker", .clear)
            #expect(rig.bus.info("worker")?.needsOwnerEnter == false)
        }
    }

    @Test func quickEchoReleasesDraftHoldThroughRealBus() throws {
        let entry = try #require(Self.cases.first { $0.id == "claude-105x14-short-draft-s300" })
        let rig = Self.makeBusRig(entry: entry)
        // 1. Owner types on empty composer.
        rig.io.show(rig.bytes.prefix(entry.beforeOffset))
        rig.bus.noteOwnerInput("worker", .text)
        // 2. Quick echo shows the draft on screen, then owner deletes it back to empty.
        rig.io.show(rig.bytes[entry.beforeOffset..<entry.beforePasteOffset])
        rig.io.show(Data("\u{1b}[2J\u{1b}[H".utf8)[...])
        rig.io.show(rig.bytes.prefix(entry.beforeOffset))
        rig.advance(4)
        rig.bus.tick()
        let body = try JSONSerialization.data(withJSONObject: ["pane": "worker", "text": "short"])
        let (_, resData) = rig.bus.handle(path: "/send", token: rig.sender, body: body)
        let res = try JSONSerialization.jsonObject(with: resData) as! [String: Any]
        #expect(res["delivered"] as? Bool == true)
        #expect(rig.bus.info("worker")?.draft == false)
        // Whole composer is visible and holds only the paste -> Enter goes out!
        let cols = entry.cols
        let rule = String(repeating: "─", count: cols)
        let footUnder = (Composer.look(kind: .claude, lines: rig.io.liveScreen().lines, cursorLine: nil)?.under ?? []).map { "  " + $0 }.joined(separator: "\r\n")
        let afterVisible = "\u{1b}[2J\u{1b}[H\(rule)\r\n❯\u{a0}[from: probe] short\r\n\(rule)\r\n\(footUnder)\r\n"
        rig.io.show(Data(afterVisible.utf8)[...])
        rig.fire()
        #expect(rig.io.enterCount == 1)
    }

    @Test func relaxedShapesHoldOnDialogBufferSwitchAndOwnerKey() throws {
        let controlIDs = ["claude-60x10-plain-s300", "claude-60x14-plain-primary-s650", "codex-60x14-m650"]
        for id in controlIDs {
            let entry = try #require(Self.cases.first { $0.id == id })
            let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(entry.id).txt")), as: UTF8.self)
            let sendBody = try JSONSerialization.data(withJSONObject: ["pane": "worker", "text": Self.sendPayload(from: pasted)])

            // Control 1: lost-hook dialog (numbered choice + key hint) holds Enter.
            do {
                let rig = Self.makeBusRig(entry: entry)
                rig.io.show(rig.bytes.prefix(entry.beforeOffset))
                _ = rig.bus.handle(path: "/send", token: rig.sender, body: sendBody)
                rig.io.show(Data("\r\n  1. Yes, allow\r\n  Enter to select · Esc to cancel\r\n".utf8)[...])
                rig.fire()
                #expect(rig.io.enterCount == 0, "\(id): dialog must hold Enter")
                #expect(rig.bus.info("worker")?.noComposer == true)
            }

            // Control 2: alternate/primary buffer switch holds Enter once harnessBuffer was learned.
            do {
                let rig = Self.makeBusRig(entry: entry)
                rig.io.show(rig.bytes.prefix(entry.beforeOffset))
                _ = rig.bus.handle(path: "/hook", token: rig.target, body: try JSONSerialization.data(withJSONObject: ["hook_event_name": "Stop"]))
                _ = rig.bus.handle(path: "/send", token: rig.sender, body: sendBody)
                rig.io.show(rig.bytes[entry.beforeOffset..<entry.afterOffset])
                let flip = (rig.io.liveScreen().alternate ?? false) ? "\u{1b}[?1049l" : "\u{1b}[?1049h"
                rig.io.show(Data(flip.utf8)[...])
                rig.fire()
                #expect(rig.io.enterCount == 0, "\(id): buffer switch must hold Enter")
            }

            // Control 3: owner key after paste drops/holds Enter even on an accepted after-screen.
            do {
                let rig = Self.makeBusRig(entry: entry)
                rig.io.show(rig.bytes.prefix(entry.beforeOffset))
                _ = rig.bus.handle(path: "/send", token: rig.sender, body: sendBody)
                rig.io.show(rig.bytes[entry.beforeOffset..<entry.afterOffset])
                rig.advance(0.05)
                rig.bus.noteOwnerInput("worker", .text)
                rig.fire()
                #expect(rig.io.enterCount == 0, "\(id): owner key after paste must stop Enter")
            }
        }
    }
}

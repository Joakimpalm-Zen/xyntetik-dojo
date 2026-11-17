import AppKit
import Foundation
import Testing
@testable import XHSApp
@testable import XHSCore

/// Red-first regressions and independent controls from the PR #118 review (F1–F4),
/// each exercised through the real `Bus` (and `TerminalPane` for screen/buffer paths).
@MainActor @Suite struct D43PR118RegressionTests {
    static let sweepDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
        .appendingPathComponent("sweep-2026-11-17")

    static let rule60 = String(repeating: "─", count: 60)
    static let claudeFoot60 = "  Usage: 5h n/a, resets at n/a · week 89% left"

    @MainActor final class SpyPaneIO: PaneIO {
        let pane: TerminalPane
        var writes: [[UInt8]] = []

        init(name: String = "worker", cols: Int = 60, rows: Int = 14) {
            _ = NSApplication.shared
            pane = TerminalPane(name: name)
            pane.resize(cols: cols, rows: rows)
        }

        var pasteCount: Int { writes.filter { $0 != Delivery.enter }.count }
        var enterCount: Int { writes.filter { $0 == Delivery.enter }.count }

        func show(_ text: String) {
            pane.show(Array(text.replacingOccurrences(of: "\n", with: "\r\n").utf8))
        }

        func showBytes(_ data: Data) { pane.show(Array(data)) }
        func write(_ bytes: [UInt8]) { writes.append(bytes) }
        func screenText() -> String { pane.screenText() }
        func visibleText() -> String { pane.visibleText() }
        func liveScreen() -> PaneScreen { pane.liveScreen() }
        func usedCells(last count: Int) -> [Int]? { pane.usedCells(last: count) }
        var columns: Int { pane.columns }
        var bracketedPasteEnabled: Bool { pane.bracketedPasteEnabled }
    }

    @MainActor struct Rig {
        let bus: Bus
        let sender: String
        let target: String
        let io: SpyPaneIO
        let getClock: () -> Date
        let stepClock: (TimeInterval) -> Void
        let triggerPending: () -> Void

        func advance(_ seconds: TimeInterval) { stepClock(seconds) }
        func fire() { triggerPending() }

        @discardableResult
        func send(_ text: String) -> [String: Any] {
            let body = try! JSONSerialization.data(withJSONObject: ["pane": "worker", "text": text])
            let (_, data) = bus.handle(path: "/send", token: sender, body: body)
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }

        func hook(_ name: String, extra: [String: Any] = [:]) {
            var payload = extra
            payload["hook_event_name"] = name
            let body = try! JSONSerialization.data(withJSONObject: payload)
            _ = bus.handle(path: "/hook", token: target, body: body)
        }
    }

    static func makeRig(kind: HarnessKind, cols: Int = 60, rows: Int = 14) -> Rig {
        let io = SpyPaneIO(cols: cols, rows: rows)
        let bus = Bus()
        var clock = Date(timeIntervalSince1970: 20_000)
        var pending: (() -> Void)?
        bus.now = { clock }
        bus.schedule = { _, work in pending = work }
        bus.submitDelay = 0.15
        let sender = bus.add(name: "probe", kind: .claude, io: nil)
        let target = bus.add(name: "worker", kind: kind, io: io)
        _ = bus.handle(path: "/hook", token: target,
                       body: try! JSONSerialization.data(withJSONObject: ["hook_event_name": "SessionStart"]))
        return Rig(
            bus: bus,
            sender: sender,
            target: target,
            io: io,
            getClock: { clock },
            stepClock: { clock.addTimeInterval($0) },
            triggerPending: {
                let work = pending
                pending = nil
                work?()
            }
        )
    }

    // MARK: F1 (P1): clear-and-repaint while echo delayed must still never press Enter on capped composer

    @Test func f1DelayedEchoAcrossScreenClearDoesNotPressEnter() throws {
        for id in ["claude-105x14-short-draft-s300", "claude-105x14-short-draft-w550"] {
            let bytes = try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).bin"))
            let manifest = try JSONDecoder().decode(
                [D43SweepScreensTests.SweepCase].self,
                from: Data(contentsOf: Self.sweepDir.appendingPathComponent("manifest.json"))
            )
            let entry = try #require(manifest.first { $0.id == id })
            let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).txt")), as: UTF8.self)
            let payload = D43SweepScreensTests.sendPayload(from: pasted)

            let rig = Self.makeRig(kind: .claude, cols: entry.cols, rows: entry.rows)
            // 1. Empty beforeOffset screen; owner types text with delayed echo.
            rig.io.showBytes(bytes.prefix(entry.beforeOffset))
            rig.bus.noteOwnerInput("worker", .text)
            // 2. Full clear-screen chunk + repaint of the old empty composer (echo still delayed).
            rig.io.showBytes(Data("\u{1b}[2J\u{1b}[H".utf8))
            rig.io.showBytes(bytes.prefix(entry.beforeOffset))
            rig.advance(4)
            rig.bus.tick()

            // 3. Peer message arrives; if Bus pastes over un-echoed draft and harness caps the box,
            //    Enter MUST NOT be sent because owner typed and head is hidden.
            _ = rig.send(payload)
            rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
            rig.fire()
            for _ in 0..<5 { rig.advance(1); rig.bus.tick() }
            #expect(rig.io.enterCount == 0, "\(id): clear-repaint reopened delayed-echo P1 Enter")
            #expect(rig.bus.info("worker")?.needsOwnerEnter == true, "\(id): header did not tell owner why")

            // 4. Owner presses Enter and composer empties -> ownerTypedUnproven clears, next capped paste gets Enter.
            rig.bus.noteOwnerInput("worker", .submit)
            rig.io.showBytes(Data("\u{1b}[2J\u{1b}[H".utf8))
            rig.io.showBytes(bytes.prefix(entry.beforeOffset))
            rig.advance(4)
            rig.bus.tick()
            #expect(rig.bus.info("worker")?.needsOwnerEnter == false)
            rig.hook("Stop")
            _ = rig.send(payload)
            rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
            rig.fire()
            #expect(rig.io.enterCount == 1, "\(id): next capped paste after owner Enter should deliver")
        }
    }

    // MARK: F2 (P2 regression): no-op Down arrow and typed-then-deleted text do not hold forever

    @Test func f2DownArrowAndDeletedTextReleaseDeliveryThroughRealBus() {
        for kind in [HarnessKind.claude, .codex, .agy] {
            // 1. Down-arrow at newest history: composer stays empty, Enter on empty composer has no hook.
            let rig = Self.makeRig(kind: kind, cols: 80, rows: 20)
            let screen: String = switch kind {
            case .codex: "\n› Ask Codex to do anything\n\n  ? for shortcuts\n"
            case .claude: "\(String(repeating: "─", count: 80))\n❯\u{a0}\n\(String(repeating: "─", count: 80))\n  Usage: 5h n/a\n"
            case .agy: "\(String(repeating: "─", count: 80))\n> \n\(String(repeating: "─", count: 80))\n  agy status\n"
            default: ""
            }
            rig.io.show("\u{1b}[2J\u{1b}[H" + screen)
            rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("\u{1b}[B".utf8)[...]))
            _ = rig.send("hello")
            rig.bus.noteOwnerInput("worker", OwnerInput.key([0x0D]))
            for _ in 0..<30 { rig.advance(1); rig.bus.tick() }
            #expect(rig.io.pasteCount == 1, "\(kind): Down arrow held delivery for 30 ticks")
            #expect(rig.bus.info("worker")?.draft == false, "\(kind): Down arrow left phantom draft flag")

            // 2. Real text key typed and deleted between paint frames (composer stayed empty on screen)
            //    must still deliver a short message whose whole composer is visible.
            let rig2 = Self.makeRig(kind: kind, cols: 80, rows: 20)
            rig2.io.show("\u{1b}[2J\u{1b}[H" + screen)
            rig2.bus.noteOwnerInput("worker", OwnerInput.key(Array("a".utf8)[...]))
            rig2.bus.noteOwnerInput("worker", OwnerInput.key([0x7F]))
            rig2.advance(4)
            let res = rig2.send("short msg")
            #expect(res["delivered"] as? Bool == true, "\(kind): deleted text between frames held delivery")
            #expect(rig2.io.pasteCount == 1)
            let afterScreen: String = switch kind {
            case .codex: "\n› [from: probe] short msg\n\n  ? for shortcuts\n"
            case .claude: "\(String(repeating: "─", count: 80))\n❯\u{a0}[from: probe] short msg\n\(String(repeating: "─", count: 80))\n  Usage: 5h n/a\n"
            case .agy: "\(String(repeating: "─", count: 80))\n> [from: probe] short msg\n\(String(repeating: "─", count: 80))\n  agy status\n"
            default: ""
            }
            rig2.io.show("\u{1b}[2J\u{1b}[H" + afterScreen)
            rig2.fire()
            #expect(rig2.io.enterCount == 1, "\(kind): whole composer holding exact paste must send Enter")
        }
    }

    // MARK: F3 (P2 regression): wide CJK and emoji characters in 60-col capped composer get Enter

    @Test func f3WideCharactersCjkAndEmojiSendEnterInCappedComposer() {
        for scalar in ["\u{754C}", "🚀"] {
            let text = String(repeating: scalar, count: 100)
            let rig = Self.makeRig(kind: .claude, cols: 60, rows: 14)
            let before = "\(Self.rule60)\n❯\u{a0}\n\(Self.rule60)\n\(Self.claudeFoot60)"
            rig.io.show("\u{1b}[2J\u{1b}[H" + before)

            let res = rig.send(text)
            #expect(res["delivered"] as? Bool == true)
            #expect(rig.io.pasteCount == 1)

            // Capped box with 3 visible rows (28 + 28 + 16 = 72 wide chars = 144 cols out of 214 cols):
            let top = "─── ↑ 1 more " + String(repeating: "─", count: 47)
            let rowA = "  " + String(repeating: scalar, count: 28)
            let rowB = "  " + String(repeating: scalar, count: 28)
            let rowC = "  " + String(repeating: scalar, count: 16)
            let after = [top, rowA, rowB, rowC, Self.rule60, Self.claudeFoot60].joined(separator: "\n")
            rig.io.show("\u{1b}[2J\u{1b}[H" + after)
            rig.fire()

            #expect(rig.io.enterCount == 1, "\(scalar): capped wide-char paste did not get Enter")
            #expect(rig.bus.info("worker")?.noComposer == false, "\(scalar): noComposer set on valid wide paste")
        }
    }

    // MARK: F4 (P2): Decoys outside recorded primary/Codex shapes must hold Enter

    @Test func f4SameBufferDecoysAndOwnControlsMustHoldEnter() {
        // Decoy A (codex F4.A): same alternate buffer, quoted message over old rule and footer (no `❯`, no top rule).
        do {
            let rig = Self.makeRig(kind: .claude, cols: 60, rows: 14)
            rig.io.show("\u{1b}[?1049h\u{1b}[2J\u{1b}[H\(Self.rule60)\n❯\u{a0}\n\(Self.rule60)\n\(Self.claudeFoot60)")
            rig.hook("Stop")
            _ = rig.send("status?")
            rig.io.show("\u{1b}[2J\u{1b}[H  [from: probe] status?\n\(Self.rule60)\n\(Self.claudeFoot60)")
            rig.fire()
            #expect(rig.io.enterCount == 0, "Decoy A: alternate-buffer quoted area triggered primary-screen reader")
            #expect(rig.bus.info("worker")?.noComposer == true)
        }

        // Decoy B (codex F4.B): Codex `↑` near column 13 instead of right edge column 60.
        do {
            let rig = Self.makeRig(kind: .codex, cols: 60, rows: 14)
            rig.io.show("\u{1b}[2J\u{1b}[H\n› Ask Codex to do anything\n\n  ? for shortcuts")
            _ = rig.send("old quote\nlast line short.")
            rig.io.show("\u{1b}[2J\u{1b}[H\n› old quote↑\n  last line short.\n\n  ? for shortcuts")
            rig.fire()
            #expect(rig.io.enterCount == 0, "Decoy B: Codex mid-line ↑ near col 13 triggered scrolled reader")
            #expect(rig.bus.info("worker")?.noComposer == true)
        }

        // Decoy C (own control #1): Primary buffer with leading blank row (box did NOT scroll off top row 0).
        do {
            let rig = Self.makeRig(kind: .claude, cols: 60, rows: 14)
            rig.io.show("\u{1b}[2J\u{1b}[H\n\(Self.rule60)\n❯\u{a0}\n\(Self.rule60)\n\(Self.claudeFoot60)")
            rig.hook("Stop")
            _ = rig.send("quoted line from transcript check")
            let decoy = [
                "",
                "  [from: probe] quoted line from transcript check",
                Self.rule60,
                Self.claudeFoot60,
            ].joined(separator: "\n")
            rig.io.show("\u{1b}[2J\u{1b}[H" + decoy)
            rig.fire()
            #expect(rig.io.enterCount == 0, "Decoy C: primary-screen non-top row unframed quote triggered Enter")
            #expect(rig.bus.info("worker")?.noComposer == true)
        }

        // Decoy D (own control #2): Codex `↑` at right column 60 WITHOUT empty separator row before footer.
        do {
            let rig = Self.makeRig(kind: .codex, cols: 60, rows: 14)
            rig.io.show("\u{1b}[2J\u{1b}[H\n› Ask Codex to do anything\n\n  ? for shortcuts")
            _ = rig.send("first line\nsecond line\nlast line short.")
            let paddedHead = "› " + "second line".padding(toLength: 57, withPad: " ", startingAt: 0) + "↑"
            let decoy = [
                "",
                paddedHead,
                "  last line short.",
                "  ? for shortcuts",
            ].joined(separator: "\n")
            rig.io.show("\u{1b}[2J\u{1b}[H" + decoy)
            rig.fire()
            #expect(rig.io.enterCount == 0, "Decoy D: Codex ↑ without footer separator empty row triggered Enter")
        }
    }

    // MARK: Re-read 9b0c4777 findings 1-3

    @Test func reread1HistoryRecallUpArrowHoldsRecalledDraft() throws {
        let id = "claude-105x14-short-draft-s300"
        let bytes = try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).bin"))
        let manifest = try JSONDecoder().decode(
            [D43SweepScreensTests.SweepCase].self,
            from: Data(contentsOf: Self.sweepDir.appendingPathComponent("manifest.json"))
        )
        let entry = try #require(manifest.first { $0.id == id })
        let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).txt")), as: UTF8.self)
        let payload = D43SweepScreensTests.sendPayload(from: pasted)

        for kind in [HarnessKind.claude, .codex, .agy, .pi] {
            let rig = Self.makeRig(kind: kind, cols: entry.cols, rows: entry.rows)
            if kind == .claude {
                rig.io.showBytes(bytes.prefix(entry.beforeOffset))
            } else {
                let empty: String = switch kind {
                case .codex: "\n› Ask Codex to do anything\n\n  ? for shortcuts\n"
                case .agy: "\(Self.rule60)\n> \n\(Self.rule60)\n  agy status\n"
                default: "pi idle\n"
                }
                rig.io.show("\u{1b}[2J\u{1b}[H" + empty)
            }
            // Owner presses CSI Up to recall a saved draft from history.
            rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("\u{1b}[A".utf8)[...]))
            if kind == .claude {
                rig.io.showBytes(bytes[entry.beforeOffset..<entry.beforePasteOffset])
            } else if kind == .codex {
                rig.io.show("\u{1b}[2J\u{1b}[H\n› wip: recalled prompt\n\n  ? for shortcuts\n")
            } else if kind == .agy {
                rig.io.show("\u{1b}[2J\u{1b}[H\(Self.rule60)\n> wip: recalled prompt\n\(Self.rule60)\n  agy status\n")
            }
            rig.advance(4)
            let res = rig.send(kind == .claude ? payload : "follow-up")
            for _ in 0..<5 { rig.advance(1); rig.bus.tick() }
            #expect(res["delivered"] as? Bool == false, "\(kind): Up-recalled draft was overwritten")
            #expect(rig.io.pasteCount == 0, "\(kind): pasted onto Up-recalled draft")
            #expect(rig.io.enterCount == 0, "\(kind): pressed Enter on Up-recalled draft")
            #expect(rig.bus.info("worker")?.draft == true, "\(kind): draft flag must stay true")
        }
    }

    @Test func reread2DialogAnswerKeyDoesNotPoisonLaterCappedDelivery() throws {
        let id = "claude-105x14-short-draft-s300"
        let bytes = try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).bin"))
        let manifest = try JSONDecoder().decode(
            [D43SweepScreensTests.SweepCase].self,
            from: Data(contentsOf: Self.sweepDir.appendingPathComponent("manifest.json"))
        )
        let entry = try #require(manifest.first { $0.id == id })
        let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).txt")), as: UTF8.self)
        let payload = D43SweepScreensTests.sendPayload(from: pasted)

        for kind in [HarnessKind.claude, .agy] {
            let rig = Self.makeRig(kind: kind, cols: entry.cols, rows: entry.rows)
            let agyRule = String(repeating: "─", count: entry.cols)
            if kind == .claude {
                rig.io.showBytes(bytes.prefix(entry.beforeOffset))
            } else {
                rig.io.show("\u{1b}[2J\u{1b}[H\(agyRule)\n> \n\(agyRule)\n  agy status\n")
            }
            rig.hook("PermissionRequest")
            #expect(rig.bus.info("worker")?.state == .prompt)
            // Owner presses "1" to answer the open dialog (not typing in the composer).
            rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("1".utf8)[...]))
            rig.hook("PostToolUse")
            rig.hook("Stop")
            rig.advance(4)
            rig.bus.tick()

            let res = rig.send(payload)
            #expect(res["delivered"] as? Bool == true, "\(kind): dialog answer poisoned delivery")
            #expect(rig.io.pasteCount == 1)
            if kind == .claude {
                rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
            } else {
                let tail = String(payload.replacingOccurrences(of: "\n", with: " ").suffix(30))
                rig.io.show("\u{1b}[2J\u{1b}[H\(agyRule)\n> ↑ 2 more lines\n  \(tail)\n\(agyRule)\n  agy status\n")
            }
            rig.fire()
            for _ in 0..<5 { rig.advance(1); rig.bus.tick() }
            #expect(rig.io.enterCount == 1, "\(kind): dialog answer blocked Enter on later capped paste")
            #expect(rig.bus.info("worker")?.needsOwnerEnter == false)
        }

        // Pager/editor on the other buffer after harnessBuffer was learned does not set ownerTypedUnproven either.
        let rig = Self.makeRig(kind: .claude, cols: entry.cols, rows: entry.rows)
        rig.io.showBytes(bytes.prefix(entry.beforeOffset))
        rig.hook("Stop")
        rig.io.show("\u{1b}[?1049l\u{1b}[2J\u{1b}[Hpager line\n")
        rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("q".utf8)[...]))
        rig.io.show("\u{1b}[?1049h")
        rig.io.showBytes(bytes.prefix(entry.beforeOffset))
        rig.advance(4)
        let pagerRes = rig.send(payload)
        #expect(pagerRes["delivered"] as? Bool == true)
        #expect(rig.bus.info("worker")?.draft == false)
        rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
        rig.fire()
        #expect(rig.io.enterCount == 1)
        #expect(rig.bus.info("worker")?.needsOwnerEnter == false)
    }

    @Test func reread3QueuedBusPasteSubmitHookDoesNotClearOwnerTypedUnproven() throws {
        let id = "claude-105x14-short-draft-s300"
        let bytes = try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).bin"))
        let manifest = try JSONDecoder().decode(
            [D43SweepScreensTests.SweepCase].self,
            from: Data(contentsOf: Self.sweepDir.appendingPathComponent("manifest.json"))
        )
        let entry = try #require(manifest.first { $0.id == id })
        let pasted = String(decoding: try Data(contentsOf: Self.sweepDir.appendingPathComponent("\(id).txt")), as: UTF8.self)
        let payload = D43SweepScreensTests.sendPayload(from: pasted)

        let rig = Self.makeRig(kind: .claude, cols: entry.cols, rows: entry.rows)
        // 1. Bus sends an earlier queued message ("queued bus task") and presses Enter.
        rig.io.showBytes(bytes.prefix(entry.beforeOffset))
        _ = rig.send("queued bus task")
        #expect(rig.io.pasteCount == 1)
        let cols = entry.cols
        let rule = String(repeating: "─", count: cols)
        let footUnder = (Composer.look(kind: .claude, lines: rig.io.liveScreen().lines, cursorLine: nil)?.under ?? [])
            .map { "  " + $0 }.joined(separator: "\r\n")
        rig.io.showBytes(Data("\u{1b}[2J\u{1b}[H\(rule)\r\n❯\u{a0}[from: probe] queued bus task\r\n\(rule)\r\n\(footUnder)\r\n".utf8))
        rig.fire()
        #expect(rig.io.enterCount == 1)
        rig.io.showBytes(Data("\u{1b}[2J\u{1b}[H".utf8))
        rig.io.showBytes(bytes.prefix(entry.beforeOffset))

        // 2. Owner types a delayed draft and hits Enter to accept completion; screen is still stale-empty.
        rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("w".utf8)[...]))
        rig.bus.noteOwnerInput("worker", OwnerInput.key([0x0D]))

        // 3. The queued bus paste's UserPromptSubmit arrives while screen looks empty: MUST NOT clear fact.
        rig.hook("UserPromptSubmit", extra: ["prompt": "[from: probe] queued bus task"])
        rig.hook("Stop")
        rig.advance(4)
        rig.bus.tick()

        // 4. Next capped message pastes onto delayed draft; head is hidden -> Enter MUST NOT be sent.
        _ = rig.send(payload)
        rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
        rig.fire()
        for _ in 0..<5 { rig.advance(1); rig.bus.tick() }
        #expect(rig.io.enterCount == 1, "unrelated queued bus hook cleared ownerTypedUnproven and allowed unsafe Enter")
        #expect(rig.bus.info("worker")?.needsOwnerEnter == true)

        // 5. Positive control: real owner submit hook (not a bus paste, after owner Enter) DOES clear it.
        rig.bus.noteOwnerInput("worker", .clear)
        rig.io.showBytes(Data("\u{1b}[2J\u{1b}[H".utf8))
        rig.io.showBytes(bytes.prefix(entry.beforeOffset))
        rig.bus.noteOwnerInput("worker", OwnerInput.key(Array("x".utf8)[...]))
        rig.bus.noteOwnerInput("worker", OwnerInput.key([0x0D]))
        rig.hook("UserPromptSubmit", extra: ["prompt": "x"])
        rig.hook("Stop")
        rig.advance(4)
        rig.bus.tick()
        _ = rig.send(payload)
        rig.io.showBytes(bytes[entry.beforeOffset..<entry.afterOffset])
        rig.fire()
        #expect(rig.io.enterCount == 2, "owner's own UserPromptSubmit should clear fact and allow next capped Enter")
    }
}

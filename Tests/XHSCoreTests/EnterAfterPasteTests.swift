import Foundation
import Testing
@testable import XHSCore

/// D26: a bus message was left in a pane's composer as pasted text, never sent. Claude Code 2.1.322 tracks the
/// mouse, so a pane gets mouse reports whenever the pointer moves over it; they counted as the owner's keys, and
/// a key in the moment between the paste and its Enter dropped the Enter for good.
@MainActor
@Suite struct EnterAfterPasteTests {
    /// A pane that takes the bus's paste now and its Enter when `fire` runs, on a clock the test moves, with the
    /// bus record in a folder of its own.
    @MainActor final class Rig {
        let bus = Bus()
        let io = MockIO()
        var pending: [() -> Void] = []
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var sender = ""
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("enter-\(UUID().uuidString)")

        init() {
            bus.submitDelay = 0.15
            bus.schedule = { [unowned self] _, work in self.pending.append(work) }
            bus.now = { [unowned self] in self.clock }
            bus.record = BusRecord(directory: folder)
            _ = bus.add(name: "claude-1", kind: .claude, io: io)
            sender = bus.add(name: "fable", kind: .claude, io: MockIO())
            bus.setState("claude-1", .idle)
        }

        func send(_ text: String) {
            let body = try! JSONSerialization.data(withJSONObject: ["pane": "claude-1", "text": text])
            _ = bus.handle(path: "/send", token: sender, body: body)
        }

        /// The moment the delayed Enter comes due.
        func fire() {
            clock += 0.15
            let work = pending
            pending = []
            for w in work { w() }
        }

        func key(_ text: String) {
            bus.noteOwnerInput("claude-1", OwnerInput.key(Array(text.utf8)[...]))
        }

        /// Seconds of ticks, one a second, as the app runs them.
        func wait(_ seconds: Int) {
            for _ in 0..<seconds { clock += 1; bus.tick() }
        }

        var enters: Int { io.written.filter { $0 == Delivery.enter }.count }

        /// The outcomes of the Enter in the record, in order.
        var outcomes: [String] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.flatMap { url in
                ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> String? in
                    guard let fields = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          fields["op"] as? String == "enter" else { return nil }
                    return fields["outcome"] as? String
                }
            }
        }
    }

    @Test func mouseMotionAndTheWheelAreNotTheOwnerTyping() {
        func key(_ bytes: [UInt8]) -> Bus.OwnerKey { OwnerInput.key(bytes[...]) }
        #expect(key(Array("\u{1b}[<35;12;7M".utf8)) == .pointer)     // motion, no button
        #expect(key(Array("\u{1b}[<32;12;7M".utf8)) == .pointer)     // a drag
        #expect(key(Array("\u{1b}[<64;5;5M".utf8)) == .pointer)      // wheel up
        #expect(key(Array("\u{1b}[<65;5;5M".utf8)) == .pointer)      // wheel down
        #expect(key([0x1B, 0x5B, 0x4D, 32 + 35, 33, 33]) == .pointer)  // legacy motion report
        #expect(key(Array("\u{1b}[<0;5;5M".utf8)) == .other)         // a click is the owner acting
        #expect(key(Array("\u{1b}[<0;5;5m".utf8)) == .other)
    }

    @Test func aMouseMoveRightAfterThePasteNoLongerStopsTheEnter() {
        let rig = Rig()
        rig.send("hello")
        #expect(rig.io.typed.contains("[from: fable] hello"))
        rig.clock += 0.05
        rig.key("\u{1b}[<35;12;7M")
        rig.fire()
        #expect(rig.enters == 1)
        #expect(rig.outcomes == ["sent"])
    }

    @Test func aKeyThatAddsNoTextLeavesTheEnterOwedUntilTheOwnerIsQuiet() {
        let rig = Rig()
        rig.send("hello")
        rig.clock += 0.05
        rig.key("\u{1b}[D")    // left arrow: moves, adds nothing
        rig.fire()
        #expect(rig.enters == 0)
        rig.wait(Int(rig.bus.ownerQuietInterval) - 1)
        #expect(rig.enters == 0)
        rig.wait(2)
        #expect(rig.enters == 1)
        #expect(rig.outcomes == ["owed", "sent"])
    }

    @Test func aPromptThatOpensLeavesTheEnterOwedUntilThePaneIsBack() {
        let rig = Rig()
        rig.send("hello")
        rig.bus.setState("claude-1", .prompt)
        rig.fire()
        #expect(rig.enters == 0)
        rig.wait(5)
        #expect(rig.enters == 0)
        rig.bus.setState("claude-1", .idle)
        rig.wait(1)
        #expect(rig.enters == 1)
        #expect(rig.outcomes == ["owed", "sent"])
    }

    /// The coordinator's condition: the bus never sends the owner's half-written words. Owner text in that
    /// composer after the paste drops the Enter for good, whenever it comes.
    @Test func ownerTextAfterThePasteMeansTheBusNeverPressesEnter() {
        // Text before the Enter's moment.
        let early = Rig()
        early.send("hello")
        early.clock += 0.05
        early.key("x")
        early.fire()
        early.wait(30)
        #expect(early.enters == 0)
        #expect(early.outcomes == ["dropped"])

        // Text after the Enter was owed, before it went.
        let late = Rig()
        late.send("hello")
        late.clock += 0.05
        late.key("\u{1b}[D")
        late.fire()
        late.wait(1)
        late.key("half-written")
        late.wait(30)
        #expect(late.enters == 0)
        #expect(late.outcomes == ["owed", "dropped"])

        // A paste of the owner's own counts as text too.
        let pasted = Rig()
        pasted.send("hello")
        pasted.bus.setState("claude-1", .prompt)
        pasted.fire()
        pasted.key("\u{1b}[200~their own words\u{1b}[201~")
        pasted.bus.setState("claude-1", .idle)
        pasted.wait(30)
        #expect(pasted.enters == 0)
    }

    @Test func theOwnersOwnEnterTakesTheOwedOneAway() {
        let rig = Rig()
        rig.send("hello")
        rig.clock += 0.05
        rig.key("\u{1b}[D")
        rig.fire()
        // The owner sees the text waiting and presses Enter before the bus would.
        rig.wait(1)
        rig.key("\r")
        rig.wait(30)
        #expect(rig.enters == 0)    // the owner's Enter went to the pane itself, not through the bus
        #expect(rig.outcomes == ["owed", "dropped"])
    }

    @Test func nothingMoreIsTypedOnTopOfAnOwedEnter() {
        let rig = Rig()
        rig.send("first")
        rig.bus.setState("claude-1", .prompt)
        rig.fire()
        rig.send("second")
        rig.wait(3)
        #expect(!rig.io.typed.contains("second"))
        rig.bus.setState("claude-1", .idle)
        rig.wait(1)
        #expect(rig.enters >= 1)
        rig.fire()
        #expect(rig.io.typed.contains("second"))
    }
}

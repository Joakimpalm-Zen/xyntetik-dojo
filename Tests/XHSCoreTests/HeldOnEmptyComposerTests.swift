import Foundation
import Testing
@testable import XHSCore

/// D37, seen live on 2026-11-15: the coordinator's pane held fifteen messages as "the owner has unsent text"
/// while its composer was empty. The pane was 129 columns wide and had once been wider; the text the bus read
/// of the composer's row was 141 characters, with the end of an old hint in columns 130 to 141. The rule that
/// ends a draft hold on an empty composer read those words as a draft.
@MainActor @Suite struct HeldOnEmptyComposerTests {
    static let width = 129
    static func row(_ text: String, beyond: String = "") -> String {
        text + String(repeating: " ", count: max(width - text.count, 0)) + beyond
    }

    /// The foot of that pane as its text gave it, word for word but for the status line's numbers.
    static let paneText: [String] = [
        "✻ Crunched for 1m 4s · done 10:39 PM · 2 shells still running",
        String(repeating: "─", count: width - 8) + " fable ─",
        row("❯\u{a0}", beyond: "ge (click) ↓"),
        row(String(repeating: "─", count: width), beyond: String(repeating: " ", count: 120)),
        row("  Usage: 5h n/a, resets at n/a · week 40% left | Ctx: 899k / 1000k | Model: Fable 5.2 | Thinking: HIGH",
            beyond: String(repeating: "─", count: 130)),
        "  ⏵⏵ bypass permissions on · 2 shells · ← 4 agents",
    ]
    /// The same rows as the live screen has them: cut at the pane's width.
    static var liveLines: [String] {
        paneText.map { String($0.prefix(width)).replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
    }

    func rig() -> PromptHookLostTests.Rig {
        let rig = PromptHookLostTests.Rig(kind: .claude, submitDelay: 0.15)
        rig.io.screen = Self.paneText.joined(separator: "\n")
        rig.io.live = Self.liveLines
        return rig
    }

    @Test func thePanesTextReadsAsADraftAndItsLiveScreenAsEmpty() {
        #expect(!Composer.shownEmpty(kind: .claude, screen: Self.paneText.joined(separator: "\n")), "what held the queue")
        #expect(Composer.shownEmpty(kind: .claude, screen: Self.liveLines.joined(separator: "\n")))
    }

    /// The owner pressed a key in the pane and took it back: the composer is empty, and no hook will say so.
    @Test func aQueueGoesOutOnceTheComposerIsEmptyWithinThePanesWidth() {
        let rig = rig()
        rig.bus.noteOwnerInput("worker", .text)
        #expect(rig.send("report")["delivered"] as? Bool == false, "the owner was typing a moment ago")
        rig.wait(5)
        #expect(rig.io.typed.contains("[from: fable] report"), "the composer is empty: the hold is over")
        #expect(rig.bus.info("worker")?.draft == false)
        #expect(rig.bus.info("worker")?.queued == 0)
    }

    /// The hold itself stays: text in the composer, within the pane's width, is the owner's.
    @Test func aRealDraftWithinThePanesWidthStillHolds() {
        let rig = rig()
        rig.io.live = Self.liveLines.map { $0.hasPrefix("❯") ? "❯\u{a0}half a thought" : $0 }
        rig.bus.noteOwnerInput("worker", .text)
        rig.send("report")
        rig.wait(30)
        #expect(rig.io.written.isEmpty)
        #expect(rig.bus.info("worker")?.draft == true)
        #expect(rig.bus.info("worker")?.queued == 1)
    }
}

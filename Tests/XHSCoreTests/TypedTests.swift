import Foundation
import Testing
@testable import XHSCore

/// D21.5: typed messages, checked by the bus and delivered as a card of plain lines.
@MainActor
@Suite struct TypedTests {
    static let examples: [(type: String, fields: [String: String], card: String)] = [
        ("assign", ["item": "D26", "what": "find the cause, then fix it", "next": "D28"],
         "assign D26\n  item: D26\n  what: find the cause, then fix it\n  next: D28"),
        ("report", ["repo": "xyntetik-dojo", "pr": "#92", "head": "E07BD8A", "checks": "ci=pass,hygiene=pass", "mergeable": "YES"],
         "report xyntetik-dojo #92\n  repo: xyntetik-dojo\n  pr: 92\n  head: e07bd8a\n  checks: ci=pass, hygiene=pass\n  mergeable: yes"),
        ("merged", ["repo": "xyntetik-dojo", "pr": "92", "sha": "8397f5b0c1", "item": "D26"],
         "merged xyntetik-dojo #92 as 8397f5b0\n  repo: xyntetik-dojo\n  pr: 92\n  sha: 8397f5b0c1\n  item: D26"),
        ("bug", ["command": "open the picker", "observed": "Choose stays on", "expected": "Choose off", "where": "picker"],
         "bug in picker\n  command: open the picker\n  observed: Choose stays on\n  expected: Choose off\n  where: picker"),
    ]

    @Test func eachTypeRendersAsItsCard() throws {
        for example in TypedTests.examples {
            let typed = try Typed.render(type: example.type, fields: example.fields).get()
            #expect(typed.text == example.card, "\(example.type)")
        }
    }

    @Test func whatIsWrongIsNamed() {
        func refusal(_ type: String, _ fields: Any?) -> String {
            if case .failure(let r) = Typed.render(type: type, fields: fields) { return r.reason }
            return "accepted"
        }
        let report: [String: String] = ["repo": "r", "pr": "1", "head": "abcdef1", "checks": "ci=pass", "mergeable": "yes"]
        #expect(refusal("poem", report).hasPrefix("unknown type poem"))
        #expect(refusal("report", nil) == "report needs fields, an object")
        #expect(refusal("report", report.merging(["colour": "teal"]) { $1 }).hasPrefix("unknown field colour for report"))
        #expect(refusal("report", report.filter { $0.key != "head" }) == "report needs head")
        #expect(refusal("report", report.merging(["pr": "ninety"]) { $1 }).hasPrefix("field pr is not a pull request number"))
        #expect(refusal("report", report.merging(["head": "xyz1234"]) { $1 }).hasPrefix("field head is not a commit SHA"))
        #expect(refusal("report", report.merging(["head": "abc12"]) { $1 }).hasPrefix("field head is not a commit SHA"))
        #expect(refusal("report", report.merging(["checks": "ci=green"]) { $1 }).hasPrefix("field checks is not checks"))
        #expect(refusal("report", report.merging(["mergeable": "maybe"]) { $1 }).hasPrefix("field mergeable is not yes, no or unknown"))
        #expect(refusal("report", report.merging(["note": "two\nlines"]) { $1 }) == "field note must be one line")
        #expect(refusal("report", report.merging(["note": "fine"]) { $1 }) == "accepted")
    }

    @Test func theTypeWordTakesTheTagsColour() {
        let color = Array("\u{1b}[32m".utf8)
        var carry: [UInt8] = []
        let out = String(decoding: Highlight.tagged(Array("[from: fable] report xyntetik-dojo #92\r\n".utf8), carry: &carry, color: color), as: UTF8.self)
        #expect(out.hasPrefix("\u{1b}[32m[from: fable] report\u{1b}[39m xyntetik-dojo"))
        // Free text that does not start with a type word keeps the tag alone in colour.
        carry = []
        let plain = String(decoding: Highlight.tagged(Array("[from: fable] reporting back\r\n".utf8), carry: &carry, color: color), as: UTF8.self)
        #expect(plain.hasPrefix("\u{1b}[32m[from: fable]\u{1b}[39m reporting"))
    }

    // MARK: on the bus

    @MainActor final class Rig {
        let bus = Bus()
        let idle = MockIO(), busy = MockIO()
        var sender = ""
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("typed-\(UUID().uuidString)")

        init() {
            bus.submitDelay = 0
            bus.record = BusRecord(directory: folder)
            // As Claude Code and Codex have it: the card's lines arrive as one paste.
            idle.bracketedPasteEnabled = true
            busy.bracketedPasteEnabled = true
            _ = bus.add(name: "idle-1", kind: .claude, io: idle)
            _ = bus.add(name: "busy-1", kind: .claude, io: busy)
            sender = bus.add(name: "fable", kind: .claude, io: MockIO())
            bus.setState("idle-1", .idle)
            bus.setState("busy-1", .running)
        }

        func send(_ args: [String: Any]) -> (Int, [String: Any]) {
            let r = bus.handle(path: "/send", token: sender, body: try! JSONSerialization.data(withJSONObject: args))
            return (r.status, json(r.body))
        }

        var sends: [[String: Any]] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return files.flatMap { url in
                ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> [String: Any]? in
                    guard let fields = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          fields["op"] as? String == "send" else { return nil }
                    return fields
                }
            }
        }
    }

    /// The coordinator's condition: each type to an idle and to a busy pane, read back from the record.
    @Test func eachTypeGoesToAnIdleAndABusyPaneAndIsInTheRecord() {
        let rig = Rig()
        for example in TypedTests.examples {
            for pane in ["idle-1", "busy-1"] {
                let (status, _) = rig.send(["pane": pane, "type": example.type, "fields": example.fields])
                #expect(status == 200, "\(example.type) to \(pane)")
            }
        }
        for (io, pane) in [(rig.idle, "idle-1"), (rig.busy, "busy-1")] {
            for example in TypedTests.examples {
                #expect(io.typed.contains("[from: fable] " + example.card), "\(example.type) typed into \(pane)")
            }
        }
        let sends = rig.sends
        #expect(sends.count == TypedTests.examples.count * 2)
        for example in TypedTests.examples {
            let mine = sends.filter { $0["type"] as? String == example.type }
            #expect(Set(mine.compactMap { $0["pane"] as? String }) == ["idle-1", "busy-1"], "\(example.type)")
            for entry in mine {
                #expect(entry["text"] as? String == example.card)
                let kept = entry["fields"] as? [String: String] ?? [:]
                let checked = (try? Typed.render(type: example.type, fields: example.fields).get().fields) ?? [:]
                #expect(kept == checked, "\(example.type)")
            }
        }
    }

    @Test func anUnknownTypeIsRefusedAndNothingIsTyped() {
        let rig = Rig()
        let (status, body) = rig.send(["pane": "idle-1", "type": "poem", "fields": ["line": "roses"]])
        #expect(status == 400)
        #expect((body["error"] as? String ?? "").hasPrefix("unknown type poem"))
        #expect(rig.idle.written.isEmpty)
        #expect(rig.send(["pane": "idle-1", "type": "bug", "text": "free text too"]).0 == 400)
        #expect(rig.idle.written.isEmpty)
    }

    @Test func aTypedMessageTakesTheSameCapAndGuardAsAnySend() {
        let rig = Rig()
        let long = String(repeating: "x", count: Bus.maxMessageLength)
        #expect(rig.send(["pane": "idle-1", "type": "bug", "fields": ["command": "c", "observed": long, "expected": "e"]]).0 == 413)
        // The owner typing in the pane holds it, as it holds text.
        rig.bus.noteOwnerInput("idle-1", .text)
        let (status, body) = rig.send(["pane": "idle-1", "type": "assign", "fields": ["item": "D1", "what": "w"]])
        #expect(status == 200)
        #expect(body["delivered"] as? Bool == false)
        #expect(!rig.idle.typed.contains("assign D1"))
    }
}

import Foundation
import Testing
@testable import XHSCore

/// D15: a pane's own label, the idle flag on a labelled pane, and the panes as a file other tools read.
/// Nothing here knows of any tool that sets a label: with none, nothing shows.
@MainActor
@Suite struct LabelLiveTests {
    final class Clock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    let bus = Bus()
    let clock = Clock()
    let ownToken: String
    let otherToken: String

    init() {
        bus.submitDelay = 0
        let clock = clock
        bus.now = { clock.date }
        ownToken = bus.add(name: "claude-1", kind: .claude, io: MockIO())
        otherToken = bus.add(name: "codex-1", kind: .codex, io: MockIO())
    }

    func label(_ text: Any?, token: String? = nil) -> (Int, [String: Any]) {
        var args: [String: Any] = [:]
        if let text { args["text"] = text }
        let r = bus.handle(path: "/label", token: token ?? ownToken, body: body(args))
        return (r.status, json(r.body))
    }

    @Test func aPaneSetsOnlyItsOwnLabel() {
        let (status, reply) = label("B11, D15")
        #expect(status == 200 && reply["pane"] as? String == "claude-1" && reply["label"] as? String == "B11, D15")
        #expect(bus.info("claude-1")?.label == "B11, D15")
        #expect(bus.info("codex-1")?.label == "")
        // A pane named in the body is not who gets it: the token says who asks
        _ = bus.handle(path: "/label", token: otherToken, body: body(["text": "mine", "pane": "claude-1"]))
        #expect(bus.info("claude-1")?.label == "B11, D15" && bus.info("codex-1")?.label == "mine")
        // Everyone sees it in the listing
        let panes = json(bus.handle(path: "/panes", token: otherToken, body: Data()).body)["panes"] as? [[String: Any]]
        #expect(panes?.first?["label"] as? String == "B11, D15")
    }

    @Test func aLabelIsOneShortLineAndEmptyClearsIt() {
        #expect(label("B11\nrm -rf /\u{1b}[2J").1["label"] as? String == "B11rm -rf /[2J")
        #expect(label(String(repeating: "x", count: Bus.maxLabelLength + 1)).0 == 413)
        #expect(label(String(repeating: "x", count: Bus.maxLabelLength)).0 == 200)
        #expect(label(nil).0 == 400)
        #expect(label(3).0 == 400)
        #expect(label("  ").1["label"] as? String == "")
        #expect(bus.info("claude-1")?.label == "")
        #expect(bus.handle(path: "/label", token: "nope", body: body(["text": "x"])).status == 401)
    }

    @Test func theRecordKeepsEachLabel() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dojo-label-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        bus.record = BusRecord(directory: dir)
        _ = label("B11")
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first)
        let lines = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8).split(separator: "\n").map { json(Data($0.utf8)) }
        #expect(lines.contains { $0["op"] as? String == "label" && $0["from"] as? String == "claude-1" && $0["label"] as? String == "B11" })
    }

    @Test func aLabelledPaneIdleTenMinutesIsFlagged() {
        var changes = 0
        bus.onChange = { changes += 1 }
        bus.setState("claude-1", .idle)
        bus.setState("codex-1", .idle)
        _ = label("B11")
        clock.date += bus.idleFlagAfter - 1
        bus.tick()
        #expect(bus.info("claude-1")?.idleFlag == nil)
        changes = 0
        clock.date += 1
        bus.tick()
        #expect(bus.info("claude-1")?.idleFlag == bus.idleFlagAfter)
        #expect(changes == 1, "the header redraws when the flag comes")
        // No label, no flag, however long it waits
        #expect(bus.info("codex-1")?.idleFlag == nil)
        // Once a minute after that, not once a second
        changes = 0
        clock.date += 30
        bus.tick()
        #expect(changes == 0)
        clock.date += 30
        bus.tick()
        #expect(changes == 1)
        // Back at work, the flag goes; idle again, the ten minutes start over
        bus.setState("claude-1", .running)
        #expect(bus.info("claude-1")?.idleFlag == nil)
        bus.setState("claude-1", .idle)
        clock.date += 60
        #expect(bus.info("claude-1")?.idleFlag == nil)
        // A prompt is not idle: the coral ring already says it waits
        bus.setState("claude-1", .prompt)
        clock.date += bus.idleFlagAfter * 2
        #expect(bus.info("claude-1")?.idleFlag == nil)
    }

    @Test func sinceIsWhenTheStateLastChanged() {
        let start = clock.date
        #expect(bus.info("claude-1")?.since == start)
        clock.date += 90
        bus.setState("claude-1", .idle)
        #expect(bus.info("claude-1")?.since == start + 90)
        clock.date += 90
        bus.setState("claude-1", .idle)
        #expect(bus.info("claude-1")?.since == start + 90, "the same state again is no change")
    }

    @Test func theFileHoldsStatesAndLabelsAndNothingElse() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dojo-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = LiveState(url: dir.appendingPathComponent("live.json"), started: clock.date)
        _ = label("B11")
        _ = bus.handle(path: "/send", token: otherToken, body: body(["pane": "claude-1", "text": "a secret message"]))
        bus.setSession("claude-1", "a-session-id")
        live.write(bus.all)
        let data = try Data(contentsOf: live.url)
        let text = String(decoding: data, as: UTF8.self)
        for kept in ["claude-1", "codex-1", "B11", "\"state\"", "\"since\"", "\"pid\"", "\"started\""] {
            #expect(text.contains(kept), "\(kept) missing")
        }
        for left in ["a secret message", "a-session-id", ownToken, otherToken, "queued", "model"] {
            #expect(!text.contains(left), "\(left) leaked")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: live.url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let panes = try #require(LiveState.read(live.url))
        #expect(panes.map { $0["name"] as? String } == ["claude-1", "codex-1"] && panes[0]["label"] as? String == "B11")
        // A file from a Dojo that is gone reads as no Dojo
        #expect(LiveState.read(live.url, alive: { _ in false }) == nil)
        live.remove()
        #expect(!FileManager.default.fileExists(atPath: live.url.path))
        #expect(LiveState.read(live.url) == nil)
    }

    @Test func manyChangesMakeOneWriteASecondAndNoneAfterQuit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dojo-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = LiveState(url: dir.appendingPathComponent("live.json"))
        var due: [() -> Void] = []
        live.schedule = { _, work in due.append(work) }
        for _ in 0..<5 { live.changed { self.bus.all } }
        #expect(due.count == 1)
        due.removeFirst()()
        #expect(LiveState.read(live.url)?.count == 2)
        // The same panes again: nothing is written
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: live.url.path)
        live.write(bus.all)
        #expect(try FileManager.default.attributesOfItem(atPath: live.url.path)[.modificationDate] as? Date == Date(timeIntervalSince1970: 0))
        // After quit, a change that was due writes nothing
        live.changed { self.bus.all }
        live.remove()
        due.removeFirst()()
        #expect(!FileManager.default.fileExists(atPath: live.url.path))
    }
}

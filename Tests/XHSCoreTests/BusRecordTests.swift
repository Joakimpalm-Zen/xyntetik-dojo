import Foundation
import Testing
@testable import XHSCore

/// The record of bus traffic (D21.2): the file format, then what the bus writes into it.
@MainActor
@Suite struct BusRecordTests {
    let folder: URL
    let record: BusRecord
    var clock = Date(timeIntervalSince1970: 1_793_000_000)   // 2026-10-26 07:33:20Z

    init() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("dojo-record-\(UUID().uuidString)")
        record = BusRecord(directory: folder)
        let start = clock
        record.now = { start }
    }

    func lines(_ file: URL? = nil) -> [[String: Any]] {
        rawLines(file).map { json(Data($0.utf8)) }
    }

    func rawLines(_ file: URL? = nil) -> [String] {
        let files = file.map { [$0] } ?? BusRecord.files(in: folder)
        return files.flatMap { f in
            ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    // MARK: the file

    @Test func eachLineCarriesTheHashOfTheLineBefore() {
        record.append(["op": "panes", "from": "a"])
        record.append(["op": "send", "from": "a", "pane": "b", "text": "hi"])
        record.append(["op": "read", "from": "b", "pane": "a", "lines": 3])
        let raw = rawLines()
        #expect(raw.count == 3)
        let parsed = lines()
        #expect(parsed[0]["prev"] as? String == BusRecord.origin)
        #expect(parsed[1]["prev"] as? String == BusRecord.hash(Data(raw[0].utf8)))
        #expect(parsed[2]["prev"] as? String == BusRecord.hash(Data(raw[1].utf8)))
        #expect(parsed[0]["time"] as? String == "2026-10-26T07:33:20.000Z")
        #expect(BusRecord.files(in: folder).map(\.lastPathComponent) == ["2026-10-26.jsonl"])
    }

    @Test func onlyTheOwnerCanReadIt() throws {
        record.append(["op": "panes", "from": "a"])
        let fm = FileManager.default
        let file = try #require(BusRecord.files(in: folder).first)
        #expect((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func theChainGoesOnAcrossLaunchesAndDays() {
        record.append(["op": "panes", "from": "a"])
        let first = rawLines()[0]
        // A new launch reads the chain's end from the file.
        let relaunched = BusRecord(directory: folder)
        let nextDay = clock.addingTimeInterval(86_400)
        relaunched.now = { nextDay }
        relaunched.append(["op": "panes", "from": "a"])
        let files = BusRecord.files(in: folder)
        #expect(files.map(\.lastPathComponent) == ["2026-10-26.jsonl", "2026-10-27.jsonl"])
        #expect(lines(files[1])[0]["prev"] as? String == BusRecord.hash(Data(first.utf8)))
    }

    @Test func filesOlderThanThirtyDaysAreDeleted() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["2026-09-20.jsonl", "2026-09-26.jsonl", "2026-09-27.jsonl", "notes.txt"] {
            FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("{}\n".utf8))
        }
        record.append(["op": "panes", "from": "a"])
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        // today is 2026-10-26: 2026-09-26 is thirty days back and stays, older files go, other files stay
        #expect(left == ["2026-09-26.jsonl", "2026-09-27.jsonl", "2026-10-26.jsonl", "notes.txt"])
    }

    // MARK: what the bus writes

    func busWithRecord() -> (Bus, MockIO, MockIO, String, String) {
        let bus = Bus()
        bus.submitDelay = 0
        bus.record = record
        let start = clock
        bus.now = { start }
        let a = MockIO(), b = MockIO()
        let ta = bus.add(name: "claude-1", kind: .claude, io: a)
        let tb = bus.add(name: "codex-1", kind: .codex, unrestricted: true, io: b)
        return (bus, a, b, ta, tb)
    }

    func op(_ name: String, _ all: [[String: Any]]) -> [[String: Any]] { all.filter { $0["op"] as? String == name } }

    @Test func aSendKeepsItsTextAndTheDeliveryTheTargetsPosture() {
        let (bus, _, b, ta, tb) = busWithRecord()
        _ = bus.handle(path: "/hook", token: tb, body: body(["hook_event_name": "SessionStart"]))
        _ = bus.handle(path: "/send", token: ta, body: body(["pane": "codex-1", "text": "please review"]))
        #expect(b.typed.contains("[from: claude-1] please review"))
        let all = lines()
        #expect(op("open", all).map { $0["posture"] as? String } == ["prompts", "unrestricted"])
        let send = op("send", all)
        #expect(send.count == 1)
        #expect(send[0]["from"] as? String == "claude-1")
        #expect(send[0]["pane"] as? String == "codex-1")
        #expect(send[0]["text"] as? String == "please review")
        #expect(send[0]["chars"] as? Int == 13)
        #expect(send[0]["outcome"] as? String == "delivered")
        let deliver = op("deliver", all)
        #expect(deliver.count == 1)
        #expect(deliver[0]["senders"] as? [String] == ["claude-1"])
        #expect(deliver[0]["posture"] as? String == "unrestricted")
        // a hook is not a line of its own; the change of state it caused is
        #expect(op("hook", all).isEmpty)
        #expect(op("pane-state", all).first?["state"] as? String == "idle")
    }

    @Test func aReadRecordsWhoReadWhomNeverTheScreen() {
        let (bus, a, _, _, tb) = busWithRecord()
        a.screen = "line one\nexport API_TOKEN=supersecret\nline three"
        _ = bus.handle(path: "/read", token: tb, body: body(["pane": "claude-1", "lines": 10]))
        let read = op("read", lines())
        #expect(read.count == 1)
        #expect(read[0]["from"] as? String == "codex-1")
        #expect(read[0]["pane"] as? String == "claude-1")
        #expect(read[0]["lines"] as? Int == 3)
        #expect(!rawLines().joined().contains("supersecret"))
    }

    @Test func aReadTakesSecretsOutAndTheScreenStaysAsItIs() {
        let (bus, a, _, ta, tb) = busWithRecord()
        let github = "gh" + "p_" + String(repeating: "a1B2", count: 9)
        let screen = "the other pane's token: \(tb)\nmine: \(ta)\nexport GITHUB_TOKEN=\(github)\nok"
        a.screen = screen
        let r = bus.handle(path: "/read", token: tb, body: body(["pane": "claude-1", "lines": 10]))
        let reply = json(r.body)
        #expect(reply["text"] as? String
            == "the other pane's token: [dojo token]\nmine: [dojo token]\nexport GITHUB_TOKEN=[redacted: github token]\nok")
        #expect(reply["redacted"] as? Int == 3)
        #expect(a.screen == screen)
        let read = op("read", lines())
        #expect(read.first?["redacted"] as? Int == 3)
        #expect(read.first?["lines"] as? Int == 4)
        #expect(!rawLines().joined().contains(github))
    }

    @Test func refusalsAreRecordedWithTheirReasonAndNoText() {
        let (bus, _, _, ta, _) = busWithRecord()
        _ = bus.handle(path: "/panes", token: "nope", body: Data())
        _ = bus.handle(path: "/send", token: ta, body: body(["pane": "nobody", "text": "hello there"]))
        _ = bus.handle(path: "/bogus", token: ta, body: Data())
        let all = lines()
        let unknown = op("panes", all)
        #expect(unknown.first?["outcome"] as? String == "refused")
        #expect(unknown.first?["status"] as? Int == 401)
        #expect(unknown.first?["from"] == nil)
        let send = op("send", all)
        #expect(send.first?["outcome"] as? String == "refused")
        #expect(send.first?["reason"] as? String == "no pane named 'nobody'")
        #expect(send.first?["text"] == nil)
        #expect(op("bogus", all).first?["status"] as? Int == 404)
    }

    @Test func theRecordSaysWhetherTheOwnersKeysAnsweredAPrompt() {
        let (bus, _, _, ta, _) = busWithRecord()
        var now = clock
        bus.now = { now }
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "SessionStart"]))
        bus.noteOwnerInput("claude-1", .submit)
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "UserPromptSubmit"]))
        now += 5
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "PermissionRequest"]))
        now += 5
        bus.noteOwnerInput("claude-1", .text)
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "PostToolUse"]))
        now += 5
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "PermissionRequest"]))
        now += 5
        _ = bus.handle(path: "/hook", token: ta, body: body(["hook_event_name": "PostToolUse"]))
        let all = lines()
        #expect(op("owner-submit", all).map { $0["pane"] as? String } == ["claude-1"])
        let left = op("pane-state", all).filter { $0["was"] as? String == "prompt" }
        #expect(left.map { $0["owner_keys"] as? Bool } == [true, false])
    }

    @Test func renamesAndClosesAreRecorded() {
        let (bus, _, _, _, _) = busWithRecord()
        #expect(bus.rename("codex-1", to: "reviewer") == nil)
        bus.remove("reviewer")
        let all = lines()
        #expect(op("rename", all).first?["to"] as? String == "reviewer")
        #expect(op("close", all).first?["pane"] as? String == "reviewer")
    }

    @Test func aBusWithoutARecordWritesNothing() {
        let bus = Bus()
        let token = bus.add(name: "claude-1", kind: .claude)
        _ = bus.handle(path: "/panes", token: token, body: Data())
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

import Darwin
import Foundation
import Testing
@testable import XHSCore

@MainActor @Suite struct D49PersistenceSweepTests {
    private static func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d49-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    // MARK: D54: OutsideRoute tampered/wrong-port/loose-mode token file

    @Test func outsideRefreshRepairsWrongPortCorruptAndLooseModeTokenFile() throws {
        let root = try Self.makeTempDir("outside")
        defer { try? FileManager.default.removeItem(at: root) }
        let switchFile = root.appendingPathComponent("outside")
        let tokenFile = root.appendingPathComponent("outside-token")
        #expect(FileManager.default.createFile(atPath: switchFile.path, contents: Data(), attributes: [.posixPermissions: 0o600]))

        let route = OutsideRoute(switchFile: switchFile, tokenFile: tokenFile, port: 7700)
        route.refresh()
        let firstToken = try #require(route.token)

        // 1. Overwrite outside-token with a stale/wrong port while switch remains active.
        let wrongPort = Data(#"{"port":9999,"token":"\#(firstToken)"}"#.utf8) + Data("\n".utf8)
        try wrongPort.write(to: tokenFile)
        route.refresh()
        let obj1 = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: tokenFile)) as? [String: Any]
        )
        #expect(obj1["port"] as? Int == 7700, "refresh() failed to rewrite outside-token when port drifted")

        // 2. Truncate/corrupt outside-token on disk.
        try Data("not-json".utf8).write(to: tokenFile)
        route.refresh()
        let obj2 = try #require(
            try JSONSerialization.jsonObject(with: try Data(contentsOf: tokenFile)) as? [String: Any]
        )
        #expect(obj2["port"] as? Int == 7700)
        #expect(obj2["token"] as? String == firstToken)

        // 3. Loosen permissions on outside-token to 0o644; refresh must restore 0o600 owner-only file.
        #expect(chmod(tokenFile.path, 0o644) == 0)
        route.refresh()
        var info = stat()
        #expect(lstat(tokenFile.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o600, "refresh() failed to restore 0o600 permissions on outside-token")
    }

    // MARK: D55: LiveState recreates externally removed live.json and blocks writes after remove()

    @Test func liveStateRecreatesDeletedFileWithIdenticalPanes() throws {
        let root = try Self.makeTempDir("live")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("live.json")
        let live = LiveState(url: url)

        live.write([])
        #expect(FileManager.default.fileExists(atPath: url.path))

        // Simulate external removal (e.g. a transient second copy exiting or manual cleanup).
        try FileManager.default.removeItem(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        live.write([])
        #expect(FileManager.default.fileExists(atPath: url.path), "write() skipped recreating deleted live.json because written cache matched")

        // Shutdown (remove) must block any delayed/subsequent write() from recreating live.json.
        live.remove()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        live.write([Bus.Info(name: "late", kind: .claude, host: "", state: .running, queued: 0, model: "",
                             draft: false, noComposer: false, needsOwnerEnter: false, role: "", reads: [],
                             label: "", since: Date(), idleFlag: nil)])
        #expect(!FileManager.default.fileExists(atPath: url.path), "write() recreated live.json after live.remove() shutdown")
    }

    // MARK: D56: BusRecord unterminated EOF line and DST spring-forward prune boundary

    @Test func busRecordSeparatesAppendAfterTruncatedLineWithoutNewline() throws {
        let root = try Self.makeTempDir("audit-eol")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = "2026-11-17"
        let file = root.appendingPathComponent("\(day).jsonl")
        let truncated = Data(#"{"op":"partial","unfinished":1"#.utf8)
        try truncated.write(to: file)

        let record = BusRecord(directory: root)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026; components.month = 11; components.day = 17; components.hour = 12
        let fixedDate = try #require(components.date)
        record.now = { fixedDate }

        record.append(["op": "send", "pane": "worker"])

        let raw = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        #expect(lines.count == 2, "new record was glued onto truncated trailing line")
        let secondLineData = Data(String(lines.last ?? "").utf8)
        let parsed = try #require(try? JSONSerialization.jsonObject(with: secondLineData) as? [String: Any])
        #expect(parsed["op"] as? String == "send")
        #expect(parsed["prev"] as? String == BusRecord.hash(truncated))
    }

    @Test func busRecordPruneUsesUTCAcrossSpringForwardDST() throws {
        let root = try Self.makeTempDir("audit-dst")
        defer { try? FileManager.default.removeItem(at: root) }
        let keptFile = root.appendingPathComponent("2026-03-02.jsonl")
        let expiredFile = root.appendingPathComponent("2026-03-01.jsonl")
        try Data("{\"op\":\"open\"}\n".utf8).write(to: keptFile)
        try Data("{\"op\":\"open\"}\n".utf8).write(to: expiredFile)

        let record = BusRecord(directory: root)
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "UTC")
        components.year = 2026; components.month = 4; components.day = 1; components.hour = 12
        let aprilFirst = try #require(components.date)
        record.now = { aprilFirst }

        record.append(["op": "open", "pane": "worker"])

        #expect(FileManager.default.fileExists(atPath: keptFile.path), "30-day-old file 2026-03-02 was deleted early across DST")
        #expect(!FileManager.default.fileExists(atPath: expiredFile.path), "31-day-old file 2026-03-01 should be pruned")
    }
}

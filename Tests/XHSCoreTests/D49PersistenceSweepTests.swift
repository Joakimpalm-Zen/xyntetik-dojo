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
}

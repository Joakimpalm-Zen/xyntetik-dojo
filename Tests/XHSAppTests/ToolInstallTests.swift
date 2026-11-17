import Foundation
import Testing
@testable import XHSApp

/// D39, an outside read: the app ran "dojo install" on its main thread before it started the bus, and the
/// install runs `agy plugin install`, which it waits up to 60 seconds for. With an agy that did not answer,
/// the app's start waited 60.3 seconds (measured under a temporary home). The install runs off the main
/// thread now, after the bus has started, and says how it went when it is done.
@Suite struct ToolInstallTests {
    /// A stand-in for the shim: says whether its stdin is /dev/null, then takes its time.
    static func standIn(_ folder: URL, sleep: Double) throws -> (script: URL, said: URL) {
        let said = folder.appendingPathComponent("said")
        let script = folder.appendingPathComponent("dojo-mcp.py")
        try """
        import os, sys, time
        null = os.stat("/dev/null")
        stdin = os.fstat(0)
        open(\(String(reflecting: said.path)), "w").write(str((stdin.st_dev, stdin.st_ino) == (null.st_dev, null.st_ino)))
        time.sleep(\(sleep))
        sys.exit(0 if sys.argv[1:] == ["install"] else 3)
        """.write(to: script, atomically: true, encoding: .utf8)
        return (script, said)
    }

    @Test func theInstallDoesNotHoldTheCallerAndSaysWhenItIsDone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tool-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (script, said) = try Self.standIn(folder, sleep: 2)
        let start = Date()
        let outcome: String? = await withCheckedContinuation { continuation in
            ToolInstall.install(script: script) { continuation.resume(returning: $0) }
            #expect(Date().timeIntervalSince(start) < 0.5, "the caller goes on at once")
        }
        #expect(outcome == nil)
        #expect(Date().timeIntervalSince(start) >= 2, "and hears once the install has ended")
        // the install never reads the terminal Dojo may have been started from
        #expect((try? String(contentsOf: said, encoding: .utf8)) == "True")
    }

    @Test func aFailedInstallIsSaid() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tool-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("dojo-mcp.py")
        try "import sys; sys.exit(1)\n".write(to: script, atomically: true, encoding: .utf8)
        let outcome: String? = await withCheckedContinuation { continuation in
            ToolInstall.install(script: script) { continuation.resume(returning: $0) }
        }
        #expect(outcome == "dojo install failed; run python3 ~/.dojo/dojo-mcp.py install")
    }
}

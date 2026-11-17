import Darwin
import Foundation
import Testing
@testable import XHSApp
@testable import XHSCore

@MainActor @Suite struct D49AppPersistenceSweepTests {
    private static func makeTempDir(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d49-app-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    // MARK: D54: AppModel.refreshOutside clears stale outside error once fixed/removed

    @Test func refreshOutsideClearsProblemWhenSwitchFixedOrRemoved() throws {
        let root = try Self.makeTempDir("outside-problem")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }

        #expect(FileManager.default.createFile(atPath: model.state.outsideSwitch.path, contents: Data(), attributes: [.posixPermissions: 0o600]))
        #expect(chmod(model.state.outsideSwitch.path, 0o666) == 0)
        model.refreshOutside()
        #expect(model.problem.hasPrefix("Sending from outside Dojo stays off:"))

        #expect(chmod(model.state.outsideSwitch.path, 0o600) == 0)
        model.refreshOutside()
        #expect(model.outside.token != nil)
        #expect(model.problem.isEmpty, "outside problem stayed in header after fixing outside switch permissions")
    }
}

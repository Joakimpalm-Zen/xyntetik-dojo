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

    // MARK: D57: AppModel.reopenLast preserves panes on total failure, defers savePanes until roles are applied, and keeps all errors

    @Test func reopenLastPreservesSavedPanesWhenAllPanesFail() throws {
        let root = try Self.makeTempDir("reopen-all-fail")
        defer { try? FileManager.default.removeItem(at: root) }

        let missingA = root.appendingPathComponent("missing-a").path
        let saved = [
            SavedPane(kind: .claude, host: "", directory: missingA, name: "coord", unrestricted: false,
                      session: "11111111-1111-1111-1111-111111111111", coordinator: true, mayRead: [])
        ]
        let panesFile = root.appendingPathComponent("panes.json")
        SavedPanes.save(saved, to: panesFile)

        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }
        model.reopenLast()

        #expect(model.items.isEmpty)
        #expect(model.lastPanes == saved, "failed reopenLast cleared lastPanes")
        #expect(SavedPanes.load(panesFile) == saved, "failed reopenLast overwrote panes.json with []")
    }

    @Test func reopenLastRestoresValidPanesAndPreservesAllErrors() throws {
        let root = try Self.makeTempDir("reopen-errors")
        defer { try? FileManager.default.removeItem(at: root) }

        let validDir = root.appendingPathComponent("valid-dir")
        try FileManager.default.createDirectory(at: validDir, withIntermediateDirectories: true)
        let missingA = root.appendingPathComponent("missing-a").path
        let missingB = root.appendingPathComponent("missing-b").path

        let saved = [
            SavedPane(kind: .claude, host: "", directory: missingA, name: "coord", unrestricted: false, session: nil, coordinator: true, mayRead: []),
            SavedPane(kind: .claude, host: "", directory: validDir.path, name: "worker", unrestricted: false, session: nil, coordinator: false, mayRead: ["coord"]),
            SavedPane(kind: .codex, host: "", directory: missingB, name: "extra", unrestricted: false, session: nil, coordinator: false, mayRead: [])
        ]
        SavedPanes.save(saved, to: root.appendingPathComponent("panes.json"))

        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }
        model.reopenLast()

        #expect(model.items.map(\.name) == ["worker"])
        #expect(model.problem.contains("coord:"), "first pane failure was overwritten by later failures: \(model.problem)")
        #expect(model.problem.contains("extra:"), "later pane failure missing from problem: \(model.problem)")
    }

    @Test func coordinatorAndReadGrantsSurviveSaveQuitAndReopen() throws {
        let root = try Self.makeTempDir("reopen-roles")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir1 = root.appendingPathComponent("dir1")
        let dir2 = root.appendingPathComponent("dir2")
        try FileManager.default.createDirectory(at: dir1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir2, withIntermediateDirectories: true)

        do {
            let model = AppModel.forTesting(stateRoot: root)
            #expect(model.addPane(kind: .claude, host: "", name: "lead", directory: dir1.path, unrestricted: false) == nil)
            #expect(model.addPane(kind: .codex, host: "", name: "worker", directory: dir2.path, unrestricted: true) == nil)
            model.markCoordinator("lead")
            model.setRead("worker", of: "lead", allowed: true)
            #expect(model.problem.isEmpty)
            model.closeAll()
            model.stopForTesting()
        }

        let reopened = AppModel.forTesting(stateRoot: root)
        defer { reopened.stopForTesting() }
        reopened.reopenLast()

        #expect(reopened.problem.isEmpty)
        #expect(reopened.bus.coordinatorName == "lead")
        #expect(reopened.bus.info("worker")?.reads == ["lead"])
        let persisted = SavedPanes.load(root.appendingPathComponent("panes.json"))
        #expect(persisted.first(where: { $0.name == "lead" })?.coordinator == true)
        #expect(persisted.first(where: { $0.name == "worker" })?.mayRead == ["lead"])
    }
}

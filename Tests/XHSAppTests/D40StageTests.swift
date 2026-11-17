import Darwin
import Foundation
import Testing
@testable import XHSApp
@testable import XHSCore

/// D40: `make stage` runs a visible copy of Dojo beside the owner's, for the README's pictures. It keeps its whole
/// state under a root of its own (~/.dojo-stage) on a port of its own, and changes nothing of the owner's: no tool
/// copy into ~/.dojo and no "dojo install". Every root and home here is a temporary folder, every port a free
/// one, and the tool calls are counted, never run.
@MainActor @Suite struct D40StageTests {
    private final class Calls: @unchecked Sendable {
        var copy = 0
        var install = 0
    }

    private static func temp(_ tag: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d40-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A port nothing listens on: the kernel's pick for a socket bound to port 0.
    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        var out = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        return Int(UInt16(bigEndian: out.sin_port))
    }

    /// Every file under `folder`, by relative path: its bytes and its mode.
    private static func snapshot(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let walk = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return out }
        for case let file as URL in walk {
            let path = String(file.path.dropFirst(folder.path.count))
            let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? -1
            let bytes = (try? Data(contentsOf: file)).map { $0.base64EncodedString() } ?? "dir"
            out[path] = "\(mode) \(bytes)"
        }
        return out
    }

    private static func stage(_ root: URL, _ calls: Calls) -> AppModel {
        AppModel(stateRoot: root, smoke: false, policy: .stage, port: freePort(),
                 tools: AppModel.Tools(copy: { calls.copy += 1; return nil }, install: { done in calls.install += 1; done(nil) }))
    }

    /// The regression that matters: a staging model started, given a pane and stopped leaves the owner's state
    /// folder as it was (record, pane list, live file, outside switch and token, tools), runs neither the tool
    /// copy nor the install, and writes its own pane list under the staging root.
    @Test func aStagingModelLeavesTheOwnersFolderAndToolsAlone() throws {
        let home = try Self.temp("home")
        defer { try? FileManager.default.removeItem(at: home) }
        let owner = home.appendingPathComponent(".dojo")
        try FileManager.default.createDirectory(at: owner.appendingPathComponent("audit"), withIntermediateDirectories: true)
        for (name, text) in [("panes.json", #"[{"kind":"claude","name":"owner-lead"}]"#), ("live.json", "owner live"),
                             ("outside", ""), ("outside-token", "owner token"), ("dojo-mcp.py", "owner shim"),
                             ("hosts", "owner@box\n"), ("audit/2026-11-17.jsonl", "owner record\n")] {
            try Data(text.utf8).write(to: owner.appendingPathComponent(name))
        }
        let before = Self.snapshot(owner)

        let root = Headless.state(smoke: false, stage: true, home: home)
        #expect(root == home.appendingPathComponent(".dojo-stage"))
        let calls = Calls()
        let model = Self.stage(root, calls)
        #expect(model.addPane(kind: .shell, host: "", name: "p1") == nil)
        // its own pane list, under its own root (read before the stop, which closes the pane)
        #expect(SavedPanes.load(root.appendingPathComponent("panes.json")).map(\.name) == ["p1"])
        model.stopForTesting()

        #expect(calls.copy == 0, "a staging copy copied the tools into ~/.dojo")
        #expect(calls.install == 0, "a staging copy ran dojo install")
        #expect(Self.snapshot(owner) == before, "a staging copy changed the owner's ~/.dojo")
    }

    /// Two copies on two roots and two ports: each holds and saves its own panes only.
    @Test func twoModelsOnTwoRootsDoNotSeeEachOthersPanes() throws {
        let rootA = try Self.temp("a"), rootB = try Self.temp("b")
        defer { try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let calls = Calls()
        let a = Self.stage(rootA, calls), b = Self.stage(rootB, calls)
        defer { a.stopForTesting(); b.stopForTesting() }
        #expect(a.addPane(kind: .shell, host: "", name: "only-a") == nil)
        #expect(b.addPane(kind: .shell, host: "", name: "only-b") == nil)
        #expect(a.items.map(\.name) == ["only-a"])
        #expect(b.items.map(\.name) == ["only-b"])
        #expect(SavedPanes.load(rootA.appendingPathComponent("panes.json")).map(\.name) == ["only-a"])
        #expect(SavedPanes.load(rootB.appendingPathComponent("panes.json")).map(\.name) == ["only-b"])
    }
}

/// D40: a Runner pane on this Mac is told where the app keeps its Runner files, and a staging copy's raises no
/// tray. A Runner pane on a host keeps its own rules.
@Suite struct D40RunnerPaneTests {
    private func plan(_ host: String?, tray: Bool) -> LaunchPlan {
        Launcher.plan(kind: .runner, paneName: "runner", host: host, port: 7798, token: "t", runnerModel: nil,
                      loginShell: "/bin/zsh", remotePort: 7801, runnerHome: "/stage/.dojo-stage/runner", runnerTray: tray)
    }

    @Test func aLocalRunnerPaneIsToldItsHomeAndAStagingOneRaisesNoTray() {
        #expect(plan(nil, tray: false).environment["DOJO_RUNNER_HOME"] == "/stage/.dojo-stage/runner")
        #expect(plan(nil, tray: false).environment["DOJO_RUNNER_TRAY"] == "off")
        #expect(plan(nil, tray: true).environment["DOJO_RUNNER_TRAY"] == nil)
        #expect(plan(nil, tray: true).environment["DOJO_RUNNER_HOME"] == "/stage/.dojo-stage/runner")
    }

    @Test func aRemoteRunnerPaneKeepsItsOwnRules() {
        let remote = plan("user@box", tray: true)
        #expect(remote.environment["DOJO_RUNNER_HOME"] == nil)
        #expect(remote.environment["DOJO_RUNNER_TRAY"] == "off")
    }
}

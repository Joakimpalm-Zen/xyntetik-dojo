import AppKit
import Foundation
import SwiftUI
import Testing
@testable import XHSApp
@testable import XHSCore

/// D45 + D46: the smoke click waits for window attachment after tab re-parenting, and every test `AppModel`
/// uses its own isolated `stateRoot` with `.test` service policy so tests never touch `~/.dojo`, install tools,
/// or bind a bus listener.
@Suite(.serialized) @MainActor struct D45SmokeFocusTests {
    private static func makeStateRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dojo-d45-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func makeHostedWindow(for model: AppModel) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView().environmentObject(model))
        window.layoutIfNeeded()
        return window
    }

    @Test func forcedPreMountClickFailsToFocusAndIsRejectedByReadinessGuard() throws {
        let root = try Self.makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }
        let window = Self.makeHostedWindow(for: model)
        defer { window.close() }

        #expect(model.addPane(kind: .shell, host: "", name: "p1") == nil)
        #expect(model.addPane(kind: .shell, host: "", name: "p2") == nil)
        let id1 = model.items.first(where: { $0.name == "p1" })!.id
        let view1 = model.items.first(where: { $0.name == "p1" })!.view

        // Forced order: `swap` and `show(tab:)` happen before SwiftUI mounts the panes in `window`.
        model.swap("p1", with: "p2")
        model.show(tab: id1)

        #expect(view1.window == nil)
        #expect(!AppModel.isClickReady(view1))
        #expect(!AppModel.clickToFocus(view1))
    }

    @Test func isClickReadyChecksWindowAttachCountVisibilityAndBounds() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let view = TerminalPane(name: "ready-check")
        #expect(!AppModel.isClickReady(view))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = container
        view.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        container.addSubview(view)
        #expect(view.windowAttachCount == 1)
        #expect(!AppModel.isClickReady(view), "bounds smaller than click point (20, 20) are not ready")

        view.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        #expect(AppModel.isClickReady(view, minAttachCount: 1))
        #expect(!AppModel.isClickReady(view, minAttachCount: 2), "must wait for next re-attach after tab switch")

        view.isHidden = true
        #expect(!AppModel.isClickReady(view, minAttachCount: 1))
        view.isHidden = false
        #expect(AppModel.isClickReady(view, minAttachCount: 1))
    }

    @Test func smokeSwapTabClickWaitsForTabReattachAndFocusesInHostedWindow() async throws {
        let root = try Self.makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }
        let window = Self.makeHostedWindow(for: model)
        defer { window.close() }

        #expect(model.addPane(kind: .shell, host: "", name: "p1") == nil)
        #expect(model.addPane(kind: .shell, host: "", name: "p2") == nil)
        let view1 = model.items.first(where: { $0.name == "p1" })!.view

        // Start the smoke click sequence immediately before SwiftUI has rendered `PaneGrid` -> `PaneCell`.
        var failure: String?
        let ok = await model.runSmokeSwapTabClick(
            name: "p1",
            partner: "p2",
            typed: "",
            deadline: Date().addingTimeInterval(5)
        ) { failure = $0 }

        #expect(ok, "expected condition wait to complete cleanly, got: \(failure ?? "nil")")
        #expect(failure == nil)
        #expect(view1.window === window)
        #expect(view1.windowAttachCount >= 2, "expected PaneGrid attach plus PaneCell tab re-attach")
        #expect(window.firstResponder === view1)

        // Switching back to the grid and repeating must also re-attach and focus via a subsequent attach count.
        let beforeSecondRound = view1.windowAttachCount
        model.show(tab: nil)
        let ok2 = await model.runSmokeSwapTabClick(
            name: "p1",
            partner: "p2",
            typed: "",
            deadline: Date().addingTimeInterval(5)
        ) { failure = $0 }

        #expect(ok2, "second swap+tab round failed: \(failure ?? "nil")")
        #expect(view1.windowAttachCount > beforeSecondRound)
        #expect(window.firstResponder === view1)
    }

    @Test func smokeSwapTabClickFailsDiagnosticWhenPaneNeverMounts() async throws {
        let root = try Self.makeStateRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel.forTesting(stateRoot: root)
        defer { model.stopForTesting() }
        #expect(model.addPane(kind: .shell, host: "", name: "p1") == nil)
        #expect(model.addPane(kind: .shell, host: "", name: "p2") == nil)

        var failure: String?
        let ok = await model.runSmokeSwapTabClick(
            name: "p1",
            partner: "p2",
            typed: "",
            deadline: Date().addingTimeInterval(0.08)
        ) { failure = $0 }

        #expect(!ok)
        #expect(failure?.contains("did not land in a window") == true)
    }

    /// D46 regression: executes the actual `D45SmokeFocusTests` inside a contained child whose fake `$HOME/.dojo`
    /// contains owner sentinel files and an active `BusRecord` chain. Verifies none of the sentinels or tools are
    /// modified, no `p1`/`p2` audit entries appear under `.dojo/audit`, and the existing writer's next append stays
    /// chain-valid.
    @Test func containedChildTestsLeaveOwnerDojoSentinelsAndAuditChainIntact() async throws {
        if ProcessInfo.processInfo.environment["DOJO_D46_CHILD_SENTINEL"] == "1" { return }

        let fm = FileManager.default
        let fakeHome = fm.temporaryDirectory.appendingPathComponent("dojo-d46-home-\(UUID().uuidString)")
        let sentinelDojo = fakeHome.appendingPathComponent(".dojo")
        let childTmp = fakeHome.appendingPathComponent("tmp")
        try fm.createDirectory(at: sentinelDojo, withIntermediateDirectories: true)
        try fm.createDirectory(at: childTmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fakeHome) }

        let sentinels: [(String, Data)] = [
            ("panes.json", Data("[{\"name\":\"owner-pane\"}]\n".utf8)),
            ("live.json", Data("{\"pid\":99999,\"panes\":[{\"name\":\"owner-pane\"}]}\n".utf8)),
            ("outside", Data()),
            ("outside-token", Data("{\"port\":7788,\"token\":\"sentinel-token\"}\n".utf8)),
            ("hosts", Data("sentinel-host\n".utf8)),
            ("folders", Data("/tmp/sentinel-folder\n".utf8)),
            ("unrestricted", Data("claude\n".utf8)),
            ("notifications", Data("sentinel-notifications\n".utf8)),
            ("dojo-mcp.py", Data("# sentinel dojo-mcp\n".utf8)),
            ("dojo-pi.ts", Data("// sentinel dojo-pi\n".utf8)),
            ("runner-start.sh", Data("#!/bin/sh\n# sentinel runner-start\n".utf8)),
        ]
        for (name, bytes) in sentinels {
            try bytes.write(to: sentinelDojo.appendingPathComponent(name))
        }

        let auditDir = sentinelDojo.appendingPathComponent("audit")
        let ownerWriter = BusRecord(directory: auditDir)
        ownerWriter.append(["op": "panes", "from": "owner"])
        ownerWriter.append(["op": "send", "from": "owner", "pane": "worker", "text": "keep"])
        let auditFilesBefore = BusRecord.files(in: auditDir)
        let auditFile = try #require(auditFilesBefore.last)
        let auditBefore = try Data(contentsOf: auditFile)

        // Build child runner arguments targeting this suite without DOJO_SMOKE set.
        let rawArgs = Array(ProcessInfo.processInfo.arguments.dropFirst())
        var childArgs: [String] = []
        var skipNext = false
        for arg in rawArgs {
            if skipNext {
                skipNext = false
                continue
            }
            if arg == "--filter" || arg == "--skip" || arg == "--xunit-output" || arg == "--event-stream-output-path" {
                skipNext = true
                continue
            }
            if arg.hasPrefix("--filter=") || arg.hasPrefix("--skip=") { continue }
            childArgs.append(arg)
        }
        if !childArgs.contains("--test-bundle-path"),
           let xctest = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            childArgs.append(contentsOf: ["--test-bundle-path", xctest.bundlePath])
        }
        childArgs.append(contentsOf: ["--filter", "D45SmokeFocusTests"])

        var env = Launcher.contained(
            ProcessInfo.processInfo.environment,
            home: fakeHome.path,
            real: fm.homeDirectoryForCurrentUser.path
        )
        env.removeValue(forKey: "DOJO_SMOKE")
        env.removeValue(forKey: "DOJO_D46_CHILD_SENTINEL")
        env["DOJO_D46_CHILD_SENTINEL"] = "1"
        env["TMPDIR"] = childTmp.path

        let status: (code: Int32, output: String) = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
                proc.arguments = childArgs
                proc.environment = env
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    cont.resume(returning: (proc.terminationStatus, String(decoding: data, as: UTF8.self)))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        #expect(status.code == 0, "contained child tests failed:\n\(status.output)")

        for (name, bytes) in sentinels {
            let url = sentinelDojo.appendingPathComponent(name)
            #expect(fm.fileExists(atPath: url.path), "sentinel \(name) was removed")
            #expect((try? Data(contentsOf: url)) == bytes, "sentinel \(name) was modified")
        }
        #expect(BusRecord.files(in: auditDir) == auditFilesBefore)
        let auditAfter = try Data(contentsOf: auditFile)
        #expect(auditAfter == auditBefore, "sentinel audit file changed during test run")
        let auditText = String(decoding: auditAfter, as: UTF8.self)
        #expect(!auditText.contains("p1") && !auditText.contains("p2"))

        // Existing real writer appends after the test run and maintains an unbroken hash chain.
        ownerWriter.append(["op": "read", "from": "owner", "pane": "worker", "lines": 1])
        let rawLines = try String(contentsOf: auditFile, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(rawLines.count == 3)
        for index in rawLines.indices {
            let obj = try #require(
                try JSONSerialization.jsonObject(with: Data(rawLines[index].utf8)) as? [String: Any]
            )
            let expectedPrev = index == 0 ? BusRecord.origin : BusRecord.hash(Data(rawLines[index - 1].utf8))
            #expect(obj["prev"] as? String == expectedPrev)
        }
    }
}

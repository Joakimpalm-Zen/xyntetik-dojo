import AppKit
import SwiftUI
import Testing
@testable import XHSApp

/// D45: the smoke click runs right after switching `selectedTab` from the grid (`PaneGrid`) to a single tab
/// (`PaneCell`). Waiting for the view to land in a window with its updated `windowAttachCount` avoids clicking
/// while `view.window` is nil or mid-teardown.
@Suite(.serialized) @MainActor struct D45SmokeFocusTests {
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

    @Test func forcedPreMountClickFailsToFocusAndIsRejectedByReadinessGuard() {
        let model = AppModel()
        defer {
            for item in model.items { model.close(item.name) }
        }
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

    @Test func smokeSwapTabClickWaitsForTabReattachAndFocusesInHostedWindow() async {
        let model = AppModel()
        defer {
            for item in model.items { model.close(item.name) }
        }
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

    @Test func smokeSwapTabClickFailsDiagnosticWhenPaneNeverMounts() async {
        let model = AppModel()
        defer {
            for item in model.items { model.close(item.name) }
        }
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
}

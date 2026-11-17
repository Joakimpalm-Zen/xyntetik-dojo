import AppKit
import SwiftUI
import Testing
@testable import XHSApp

/// D45: the smoke click runs right after switching `selectedTab` from the grid (`PaneGrid`) to a single tab
/// (`PaneCell`). When SwiftUI has not yet finished tearing down `PaneGrid` and mounting `PaneCell` within the
/// fixed timer gap (or before the initial window renders), `view.window` is nil and `mouseDown` fails to make
/// the pane first responder ("a click did not focus the pane").
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

    private static func click(_ view: TerminalPane) {
        view.window?.makeFirstResponder(nil)
        view.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!)
        view.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        )!)
    }

    @Test func clickImmediatelyAfterAddAndTabSwitchBeforeMountFailsToFocus() async {
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

        // Forced CI-stall order: `swap` and `show(tab:)` fire before SwiftUI finishes mounting the view into its
        // target window, matching what happens when `runSmoke`'s blind `asyncAfter` timers fire before render.
        model.swap("p1", with: "p2")
        model.show(tab: id1)
        Self.click(view1)

        #expect(view1.window?.firstResponder === view1)
    }
}

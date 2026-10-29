import AppKit
import SwiftUI

@main
struct XHSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Xyntetik Harness Supervisor", id: "main") {
            ContentView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            NSApp.setActivationPolicy(.regular)
            // Paper is the same colour by night: the controls stay in their light form under dark mode.
            NSApp.appearance = NSAppearance(named: .aqua)
            for window in NSApp.windows {
                window.backgroundColor = Theme.bg
                window.titlebarAppearsTransparent = true
                AppDelegate.tintTitle(window)
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                    MainActor.assumeIsolated { if let window = note.object as? NSWindow { AppDelegate.tintTitle(window) } }
                }
            }
            let model = AppModel.shared
            if model.smoke {
                model.runSmoke()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// The window's name in the brand green. AppKit draws the title in a text field inside the title bar;
    /// this finds it by its text and recolours it, again whenever the window gains or loses focus.
    static func tintTitle(_ window: NSWindow) {
        func visit(_ view: NSView) {
            if let field = view as? NSTextField, field.stringValue == window.title {
                field.textColor = Theme.brand
            }
            view.subviews.forEach(visit)
        }
        if let root = window.contentView?.superview { visit(root) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.closeAll() }
    }
}

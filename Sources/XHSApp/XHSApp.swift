import AppKit
import SwiftUI

@main
struct XHSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Xyntetik Dojo", id: "main") {
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
                AppDelegate.addMark(to: window)
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

    /// The Dojo mark in the title bar, before the window's name.
    static func addMark(to window: NSWindow) {
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier?.rawValue == "dojo-mark" }) else { return }
        let accessory = NSTitlebarAccessoryViewController()
        let hosting = NSHostingView(rootView: EnsoMark().frame(width: 20, height: 20).padding(.leading, 6).padding(.trailing, 4))
        hosting.identifier = NSUserInterfaceItemIdentifier("dojo-mark")
        hosting.frame = NSRect(x: 0, y: 0, width: 30, height: 22)
        accessory.view = hosting
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
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

    /// Cmd-W or Cmd-Q with sessions running ends every one of them, so it asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let live = AppModel.shared.livePanes
            guard live > 0, !AppModel.shared.smoke else { return .terminateNow }
            let alert = NSAlert()
            alert.messageText = "Quit Xyntetik Dojo?"
            alert.informativeText = live == 1 ? "One session is still running; quitting ends it." : "\(live) sessions are still running; quitting ends them all."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.closeAll() }
    }
}

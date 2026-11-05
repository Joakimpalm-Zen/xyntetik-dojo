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
        .commands {
            // Text size for every pane, as in any terminal app.
            CommandGroup(after: .toolbar) {
                Button("Bigger Text") { model.zoom(1) }.keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { model.zoom(-1) }.keyboardShortcut("-", modifiers: .command)
                Button("Default Text Size") { model.zoom(nil) }.keyboardShortcut("0", modifiers: .command)
            }
            // The tabs: All on Cmd-1, the first eight panes on Cmd-2 to Cmd-9, and the step keys Terminal.app uses.
            CommandMenu("Tabs") {
                Button("All") { model.show(tab: nil) }.keyboardShortcut("1", modifiers: .command)
                ForEach(Array(model.agents.prefix(8).enumerated()), id: \.element.id) { i, item in
                    Button(item.name) { model.show(tab: item.id) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 2))), modifiers: .command)
                }
                Divider()
                Button("Next Tab") { model.stepTab(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { model.stepTab(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            }
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
                // The centred toolbar item contains both the mark and name. Keep the native controls.
                window.titleVisibility = .hidden
            }
            let model = AppModel.shared
            if model.smoke {
                model.runSmoke()
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
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

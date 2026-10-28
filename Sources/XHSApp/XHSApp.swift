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
            for window in NSApp.windows {
                window.backgroundColor = Theme.bg
                window.titlebarAppearsTransparent = true
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

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.closeAll() }
    }
}

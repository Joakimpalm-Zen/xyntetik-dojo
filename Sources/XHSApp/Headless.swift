import AppKit
import ObjectiveC
import XHSCore

/// A launch proof with no person at the screen (DOJO_SMOKE=1), which must leave the running Dojo and its
/// owner alone. The app has no Dock icon and never activates, its window sits off every screen, where it
/// still lays out and draws, and everything is decided before the first window exists, so nothing can flash.
@MainActor
enum Headless {
    nonisolated static let isRequested = ProcessInfo.processInfo.environment["DOJO_SMOKE"] == "1"
    /// The installed app's preferences. AppKit keeps the window frame there, among others, so a smoke runs
    /// under another identifier (`make smoke` makes the copy): no key in them, today's or a later one, is reachable.
    private static let ownersBundle = "com.xyntetik.dojo"
    private static let origin = NSPoint(x: -30000, y: -30000)

    static func begin() {
        guard isRequested else { return }
        if let refusal = refusal(bundle: Bundle.main.bundleIdentifier) {
            print("DOJO_SMOKE failed: \(refusal)")
            exit(1)
        }
        contain()
        // Before any window or pane: a smoke that cannot leave the owner's home alone does not run.
        if let leak = leak(real: realHome) {
            print("DOJO_SMOKE failed: \(leak)")
            exit(1)
        }
        // In memory only.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true, "NSQuitAlwaysKeepsWindows": false])
        exchange(NSWindow.self, "makeKeyAndOrderFront:", "dojo_makeKeyAndOrderFront:")
        exchange(NSWindow.self, "orderFront:", "dojo_orderFront:")
        exchange(NSWindow.self, "orderFrontRegardless", "dojo_orderFrontRegardless")
        exchange(NSWindow.self, "constrainFrameRect:toScreen:", "dojo_constrainFrameRect:toScreen:")
        exchange(NSApplication.self, "activateIgnoringOtherApps:", "dojo_activateIgnoringOtherApps:")
        exchange(NSApplication.self, "activate", "dojo_activate")
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Why a smoke may not run as this bundle; nil when it may.
    static func refusal(bundle: String?) -> String? {
        bundle == ownersBundle ? "this copy shares \(ownersBundle) with the installed app; run make smoke" : nil
    }

    /// The owner's home whatever the environment says, from the user database.
    nonisolated static var realHome: String {
        getpwuid(getuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
    }

    /// A smoke's home: a throwaway folder, with the state inside it where ~/.dojo would be.
    nonisolated private static var smokeHome: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("dojo-smoke-\(getpid())")
    }

    /// Moves this process, and so every process it starts, off the owner's home, before anything has looked at
    /// it. Here and not at each launch, so that no path can forget: a pane, a login shell, a probe or a tool
    /// finds only the throwaway home, and `$HOME/.dojo` is the throwaway state.
    private static func contain() {
        let home = smokeHome
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let before = ProcessInfo.processInfo.environment
        let after = Launcher.contained(before, home: home.path, real: realHome)
        for key in before.keys where after[key] == nil { unsetenv(key) }
        for (key, value) in after where before[key] != value { setenv(key, value, 1) }
    }

    /// How this process can still reach `real`, the owner's home; nil when it cannot.
    nonisolated static func leak(real: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                                 foundationHome: String = NSHomeDirectory(),
                                 fileManagerHome: String = FileManager.default.homeDirectoryForCurrentUser.path,
                                 state: String = Headless.state().path) -> String? {
        let dojo = real + "/.dojo"
        let homes = ["HOME": environment["HOME"] ?? "", "NSHomeDirectory": foundationHome, "FileManager": fileManagerHome]
        for (name, home) in homes.sorted(by: { $0.key < $1.key }) where home.isEmpty || home == real || home == real + "/" {
            return "\(name) is still the owner's home"
        }
        if state == dojo || state.hasPrefix(dojo + "/") { return "the app's state is the owner's" }
        for name in ["ZDOTDIR", "DOJO_RUNNER_HOME"] where environment[name] != nil { return "\(name) is still set" }
        return nil
    }

    /// The folder for what the app keeps between launches: ~/.dojo, or for a smoke a throwaway one, so that
    /// it neither reads nor writes what the live panes use.
    nonisolated static func state(smoke: Bool = isRequested, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        (smoke ? smokeHome : home).appendingPathComponent(".dojo")
    }

    private static func exchange(_ type: AnyClass, _ original: String, _ replacement: String) {
        guard let first = class_getInstanceMethod(type, NSSelectorFromString(original)),
              let second = class_getInstanceMethod(type, NSSelectorFromString(replacement)) else { return }
        method_exchangeImplementations(first, second)
    }

    /// Off every screen, and with no saved frame.
    static func park(_ window: NSWindow) {
        window.setFrameAutosaveName("")
        window.isRestorable = false
        window.ignoresMouseEvents = true
        // Should anything ever pull the window back, there is still nothing to see.
        window.alphaValue = 0
        if !window.isSheet, window.frame.origin != origin { window.setFrameOrigin(origin) }
    }

    /// What is wrong with this window for a run with no person, if anything.
    static func problem(with window: NSWindow, visible: Bool) -> String? {
        guard visible, NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { return nil }
        return "window \"\(window.title)\" (\(type(of: window))) is on screen at \(window.frame)"
    }

    /// Everything that reached the owner: windows on a screen, and the keyboard. Empty is what a smoke must keep it.
    static var problems: [String] {
        var found = NSApp.windows.compactMap { problem(with: $0, visible: $0.isVisible) }
        if NSApp.isActive { found.append("the app became active, so it holds the keyboard") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() { found.append("the app is frontmost") }
        return found
    }
}

extension NSWindow {
    @objc func dojo_makeKeyAndOrderFront(_ sender: Any?) {
        Headless.park(self)
        dojo_makeKeyAndOrderFront(sender)
    }

    @objc func dojo_orderFront(_ sender: Any?) {
        Headless.park(self)
        dojo_orderFront(sender)
    }

    @objc func dojo_orderFrontRegardless() {
        Headless.park(self)
        dojo_orderFrontRegardless()
    }

    /// AppKit would pull a window back onto a screen here.
    @objc func dojo_constrainFrameRect(_ rect: NSRect, toScreen screen: NSScreen?) -> NSRect { rect }
}

extension NSApplication {
    @objc func dojo_activateIgnoringOtherApps(_ flag: Bool) {}
    @objc func dojo_activate() {}
}

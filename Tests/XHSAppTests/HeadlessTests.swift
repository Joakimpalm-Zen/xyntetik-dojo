import AppKit
import Testing
@testable import XHSApp

@Suite @MainActor struct HeadlessTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Under test"
        return window
    }

    @Test func aParkedWindowLeavesNoFrameBehindAndIsOffEveryScreen() {
        let window = window()
        window.setFrameAutosaveName("headless-test")
        Headless.park(window)
        #expect(window.frameAutosaveName.isEmpty)
        #expect(!window.isRestorable)
        #expect(!NSScreen.screens.contains { $0.frame.intersects(window.frame) })
    }

    @Test func aWindowOnAScreenIsNamedWithItsFrame() throws {
        let screen = try #require(NSScreen.screens.first, "needs a screen")
        let window = window()
        window.setFrameOrigin(screen.frame.origin)
        let problem = Headless.problem(with: window, visible: true)
        #expect(problem?.contains("Under test") == true)
        #expect(problem?.contains("on screen") == true)
    }

    @Test func aHiddenOrParkedWindowIsNoProblem() {
        let window = window()
        #expect(Headless.problem(with: window, visible: false) == nil)
        Headless.park(window)
        #expect(Headless.problem(with: window, visible: true) == nil)
    }

    @Test func theInstalledAppsPreferencesAreRefused() {
        #expect(Headless.refusal(bundle: "com.xyntetik.dojo") != nil)
        #expect(Headless.refusal(bundle: "com.xyntetik.dojo.smoke") == nil)
    }

    @Test func aSmokeKeepsItsStateOutOfTheOwnersFolder() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(Headless.state(smoke: false, home: home) == home.appendingPathComponent(".dojo"))
        #expect(!Headless.state(smoke: true, home: home).path.hasPrefix(home.path))
    }
}

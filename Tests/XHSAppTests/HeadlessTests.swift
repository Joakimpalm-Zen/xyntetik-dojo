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

    private func leak(_ environment: [String: String] = ["HOME": "/tmp/h"], foundation: String = "/tmp/h", fileManager: String = "/tmp/h",
                      state: String = "/tmp/h/.dojo") -> String? {
        Headless.leak(real: "/Users/me", environment: environment, foundationHome: foundation, fileManagerHome: fileManager, state: state)
    }

    @Test func aContainedRunHasNoLeak() {
        #expect(leak() == nil)
    }

    @Test func everyWayBackToTheOwnersHomeIsALeak() {
        #expect(leak(["HOME": "/Users/me"]) != nil)
        #expect(leak([:]) != nil)
        #expect(leak(foundation: "/Users/me") != nil)
        #expect(leak(fileManager: "/Users/me/") != nil)
        #expect(leak(state: "/Users/me/.dojo") != nil)
        #expect(leak(state: "/Users/me/.dojo/runner") != nil)
        #expect(leak(["HOME": "/tmp/h", "ZDOTDIR": "/Users/me"]) != nil)
        #expect(leak(["HOME": "/tmp/h", "DOJO_RUNNER_HOME": "/Users/me/.dojo/runner"]) != nil)
    }

    @Test func theRealHomeComesFromTheUserDatabaseAndNotTheEnvironment() {
        setenv("HOME", "/tmp/elsewhere", 1)
        defer { setenv("HOME", NSHomeDirectory(), 1) }
        #expect(Headless.realHome != "/tmp/elsewhere")
        #expect(Headless.realHome.hasPrefix("/"))
    }
}

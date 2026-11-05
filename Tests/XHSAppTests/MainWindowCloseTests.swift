import AppKit
import Testing
@testable import XHSApp

@Suite @MainActor struct MainWindowCloseTests {
    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func cancelledQuitNeverClosesTheWindowAndCanBeRetried() {
        let window = window()
        let original = WindowDelegate()
        var requests = 0
        let delegate = MainWindowCloseDelegate(original: original) { requests += 1 }
        window.delegate = delegate
        for _ in 0..<3 { window.performClose(nil) }
        #expect(requests == 3)
        #expect(original.closeChecks == 3)
        #expect(original.closed == 0)
        #expect(window.delegate === delegate)
        // The existing close notification still reaches the original delegate.
        window.close()
        #expect(original.closed == 1)
    }

    @Test func originalDelegateCanVetoClose() {
        let window = window()
        let original = WindowDelegate()
        original.allowClose = false
        var requests = 0
        let delegate = MainWindowCloseDelegate(original: original) { requests += 1 }
        #expect(!delegate.windowShouldClose(window))
        #expect(original.closeChecks == 1)
        #expect(requests == 0)
        window.close()
    }

    @Test func nestedCloseDoesNotRequestQuitTwice() {
        let window = window()
        var requests = 0
        let delegate = MainWindowCloseDelegate(original: nil) {
            requests += 1
            window.performClose(nil)
        }
        window.delegate = delegate
        window.performClose(nil)
        #expect(requests == 1)
        window.close()
    }

    @Test func forwardsOptionalDelegateMethods() {
        let window = window()
        let original = WindowDelegate()
        let delegate = MainWindowCloseDelegate(original: original) {}
        let forwarded: NSWindowDelegate = delegate
        #expect(delegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))))
        #expect(forwarded.windowWillResize?(window, to: NSSize(width: 100, height: 100))
                == NSSize(width: 640, height: 400))
        #expect(!delegate.responds(to: #selector(NSWindowDelegate.windowShouldZoom(_:toFrame:))))
        window.close()
    }
}

private final class WindowDelegate: NSObject, NSWindowDelegate {
    var allowClose = true
    var closeChecks = 0
    var closed = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeChecks += 1
        return allowClose
    }

    func windowWillClose(_ notification: Notification) { closed += 1 }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        NSSize(width: 640, height: 400)
    }
}

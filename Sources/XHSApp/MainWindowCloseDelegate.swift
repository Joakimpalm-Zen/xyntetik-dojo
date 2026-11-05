import AppKit

/// Keep the window alive until the application's quit confirmation has succeeded.
/// Forward all other callbacks to SwiftUI's window delegate.
final class MainWindowCloseDelegate: NSObject, NSWindowDelegate {
    private weak var original: NSWindowDelegate?
    private let requestQuit: () -> Void
    private var requestingQuit = false

    init(original: NSWindowDelegate?, requestQuit: @escaping () -> Void) {
        self.original = original
        self.requestQuit = requestQuit
        super.init()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !requestingQuit else { return false }
        requestingQuit = true
        defer { requestingQuit = false }
        guard original?.windowShouldClose?(sender) != false else { return false }
        // Termination has the only confirmation prompt. It does not call windowShouldClose.
        // Always veto the window close, including when termination is cancelled.
        requestQuit()
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if original?.responds(to: selector) == true { return original }
        return super.forwardingTarget(for: selector)
    }
}

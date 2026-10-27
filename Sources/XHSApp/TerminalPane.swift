import AppKit
import SwiftTerm
import XHSCore

/// One terminal: a SwiftTerm view with its pty, readable and writable by the bus.
@MainActor
final class TerminalPane: LocalProcessTerminalView, PaneIO {
    let paneName: String

    init(name: String) {
        paneName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        configureNativeColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func write(_ bytes: [UInt8]) {
        send(data: bytes[...])
    }

    func screenText() -> String {
        String(decoding: getBufferAsData(), as: UTF8.self)
    }

    var bracketedPasteEnabled: Bool {
        terminalInputStateSnapshot()?.bracketedPasteMode ?? false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        configureNativeColors()
    }
}

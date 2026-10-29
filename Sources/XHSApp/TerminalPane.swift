import AppKit
import SwiftTerm
import XHSCore

/// One terminal: a SwiftTerm view with its pty, readable and writable by the bus.
@MainActor
final class TerminalPane: LocalProcessTerminalView, PaneIO {
    /// The pane's name on the bus; a rename changes it.
    var paneName: String

    init(name: String) {
        paneName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyTheme()
    }

    /// Paper and ink for the terminal; the ANSI palette stays the harnesses' own.
    private func applyTheme() {
        nativeBackgroundColor = Theme.paper
        nativeForegroundColor = Theme.ink
        caretColor = Theme.teal
        selectedTextBackgroundColor = Theme.teal.withAlphaComponent(0.35)
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

    // MARK: relayed messages in the brand green

    /// Bytes from the harness that might be the start of a `[from: <name>]` tag, held for the next chunk.
    private var carry: [UInt8] = []
    /// A control sequence cut off at the end of a chunk, held for the next.
    private var sequenceCarry: [UInt8] = []
    private var flush: DispatchWorkItem?

    /// `Theme.brand` as a terminal colour code.
    private static let tagColor = Highlight.foreground(red: 0x14, green: 0xA0, blue: 0x8F)

    /// On the way from the harness to the screen, a white background becomes the paper shade and every
    /// `[from: <name>]` tag is wrapped in the Xyntetik green.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        flush?.cancel()
        let repainted = Repaint.apply(Array(slice), carry: &sequenceCarry, shade: Theme.shade)
        let out = Highlight.tagged(repainted, carry: &carry, color: TerminalPane.tagColor)
        if !out.isEmpty { feed(byteArray: out[...]) }
        if !carry.isEmpty || !sequenceCarry.isEmpty {
            // A chunk ended inside a possible tag or sequence; if nothing follows at once, show the bytes as they are.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let held = self.sequenceCarry + self.carry
                self.sequenceCarry = []
                self.carry = []
                if !held.isEmpty { self.feed(byteArray: held[...]) }
            }
            flush = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }
    }
}

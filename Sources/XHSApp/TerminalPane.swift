import AppKit
import SwiftTerm
import XHSCore

/// One terminal: a SwiftTerm view with its own pty process, readable and writable by the bus.
///
/// The pane owns the process itself so that every byte from the harness passes `dataReceived` on its way
/// to the screen: SwiftTerm's own LocalProcessTerminalView feeds the screen through a private adapter and
/// never calls that method on a subclass.
@MainActor
final class TerminalPane: TerminalView, PaneIO {
    /// The pane's name on the bus; a rename changes it.
    var paneName: String
    /// Called on the main thread when the process ends, with its exit code.
    var onExit: ((Int32?) -> Void)?
    private var process: LocalProcess!

    init(name: String) {
        paneName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        applyTheme()
        terminalDelegate = self
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    /// Paper and ink for the terminal; the ANSI palette stays the harnesses' own.
    private func applyTheme() {
        nativeBackgroundColor = Theme.paper
        nativeForegroundColor = Theme.ink
        caretColor = Theme.teal
        selectedTextBackgroundColor = Theme.teal.withAlphaComponent(0.35)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: the process

    func startProcess(executable: String, args: [String], environment: [String]?, execName: String?, currentDirectory: String?) {
        process.startProcess(executable: executable, args: args, environment: environment, execName: execName,
                             currentDirectory: currentDirectory)
    }

    func terminate() {
        process.terminate()
    }

    private func windowSize() -> winsize {
        let dimensions = terminalDimensions
        return winsize(ws_row: UInt16(dimensions.rows), ws_col: UInt16(dimensions.cols),
                       ws_xpixel: UInt16(bounds.width), ws_ypixel: UInt16(bounds.height))
    }

    // MARK: PaneIO

    func write(_ bytes: [UInt8]) {
        process.send(data: bytes[...])
    }

    func screenText() -> String {
        String(decoding: getBufferAsData(), as: UTF8.self)
    }

    /// Only the visible rows: cheap enough to take once a second for every pane, unlike the whole buffer.
    func visibleText() -> String {
        visibleRowsText(0..<terminalDimensions.rows).joined(separator: "\n")
    }

    var bracketedPasteEnabled: Bool {
        terminalInputStateSnapshot()?.bracketedPasteMode ?? false
    }

    /// Frames are drawn on the GPU: a harness repaints its whole screen many times a second, which the
    /// CoreGraphics path draws on the main thread, glyph by glyph. SwiftTerm leaves Metal off by default.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, !isUsingMetalRenderer { try? setUseMetal(true) }
    }

    // MARK: bytes from the harness

    /// Bytes from the harness that might be the start of a `[from: <name>]` tag, held for the next chunk.
    private var carry: [UInt8] = []
    /// A control sequence cut off at the end of a chunk, held for the next.
    private var sequenceCarry: [UInt8] = []
    private var flush: DispatchWorkItem?

    /// `Theme.brand` as a terminal colour code.
    private static let tagColor = Highlight.foreground(red: 0x14, green: 0xA0, blue: 0x8F)

    /// On the way from the harness to the screen, a white background becomes the paper shade and every
    /// `[from: <name>]` tag is wrapped in the Xyntetik green.
    private func show(_ bytes: [UInt8]) {
        flush?.cancel()
        let repainted = Repaint.apply(bytes, carry: &sequenceCarry, shade: Theme.shade)
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

// The process delivers on the main queue (see init), so these run on the main actor.
extension TerminalPane: LocalProcessDelegate {
    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { show(Array(slice)) }
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { onExit?(exitCode) }
    }

    nonisolated func getWindowSize() -> winsize {
        if Thread.isMainThread { return MainActor.assumeIsolated { windowSize() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { windowSize() } }
    }
}

extension TerminalPane: TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = windowSize()
        process.updateWindowSize(&size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { TerminalView.openDefaultLink(link) }
    func bell(source: TerminalView) { NSSound.beep() }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func kittyClipboardCapabilities(source: TerminalView) -> KittyClipboardCapabilities { [] }
    func kittyClipboardAvailableMimeTypes(source: TerminalView, location: KittyClipboardLocation) -> [String]? { nil }
    func kittyClipboardRead(source: TerminalView, location: KittyClipboardLocation, mimeType: String) -> KittyClipboardReadResult? { nil }
    func kittyClipboardWrite(source: TerminalView, location: KittyClipboardLocation, content: KittyClipboardWriteContent) -> KittyClipboardWriteResult { .unsupported }
    func kittyClipboardRequestPermission(source: TerminalView, request: KittyClipboardPermissionRequest) -> KittyClipboardPermissionResult { .deny }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

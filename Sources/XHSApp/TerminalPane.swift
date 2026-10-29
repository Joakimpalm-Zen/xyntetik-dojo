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
    /// SF Mono at this size: a shade smaller than Terminal.app's Courier 10.5 reads. Cmd-plus, Cmd-minus
    /// and Cmd-0 change every pane's size while the app runs; the size is not kept between launches.
    static let defaultFontSize: CGFloat = 11

    /// The pane's name on the bus; a rename changes it.
    var paneName: String
    /// Called on the main thread when the process ends, with its exit code.
    var onExit: ((Int32?) -> Void)?
    /// Called with what each batch of the owner's keystrokes did to the composer.
    var onOwnerInput: ((Bus.OwnerKey) -> Void)?
    private var process: LocalProcess!

    init(name: String) {
        paneName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        font = NSFont.monospacedSystemFont(ofSize: TerminalPane.defaultFontSize, weight: .regular)
        applyTheme()
        terminalDelegate = self
        process = LocalProcess(delegate: self, dispatchQueue: .main)
    }

    /// Paper, Novel's ink and Novel's sixteen colours for the terminal.
    private func applyTheme() {
        nativeBackgroundColor = Theme.paper
        nativeForegroundColor = Theme.terminalInk
        installColors(Theme.ansi.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257, blue: UInt16(rgb & 0xFF) * 257)
        })
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

    /// A click focuses the pane. With the Metal surface up the click lands on the GPU layer's view, which
    /// takes no focus, so AppKit would not move the first responder here by itself; a pane that lost focus
    /// (a swap re-parents it) would then never take keys again.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
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
                // Stream order: the tag carry holds the end of the repainted output, the sequence carry
                // the raw tail after it.
                let held = self.carry + self.sequenceCarry
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
        onOwnerInput?(OwnerInput.key(data))
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

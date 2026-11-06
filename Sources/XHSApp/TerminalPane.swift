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
    /// The font every pane starts with: SF Mono Regular at 10.5 points, drawn with font smoothing. The owner
    /// picked it on 2026-11-06 from a sheet of seven standard fonts, each rendered by this app off screen with
    /// and without smoothing (cell G2). Three earlier settings chosen from offline measurements each looked
    /// wrong on the screen, so change this only from a new sheet of real renders, never from numbers alone.
    ///
    /// The half point is for the grid: SwiftTerm snaps a cell to whole pixels, and at 10.5 points a letter is
    /// 12.98 pixels wide on a Retina screen in a 13 pixel cell. At 11 points it would stand 2.9% apart.
    /// Cmd-plus, Cmd-minus and Cmd-0 change every pane's size while the app runs; the size is not kept
    /// between launches.
    static let defaultFont = font(ofSize: 10.5)
    /// The distance between rows as a multiple of the font's line height: 15 points at the default size.
    static let rowSpacing: CGFloat = 1.2

    /// The pane font at `size`.
    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The pane's name on the bus; a rename changes it.
    var paneName: String
    /// Called on the main thread when the process ends, with its exit code.
    var onExit: ((Int32?) -> Void)?
    /// Called with what each batch of the owner's keystrokes did to the composer.
    var onOwnerInput: ((Bus.OwnerKey) -> Void)?
    /// Called each time the pane arrives in a window, as a move between the grid and a tab does.
    var onLanded: (() -> Void)?
    private var process: LocalProcess!

    init(name: String) {
        paneName = name
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        // With font smoothing, as in the cell the owner picked: see `defaultFont`.
        fontSmoothing = true
        setTextSize(TerminalPane.defaultFont.pointSize)
        applyTheme()
        terminalDelegate = self
        process = LocalProcess(delegate: self, dispatchQueue: .main)
        // Files and folders dropped from the Finder: their paths land in the composer, as in Terminal.app.
        registerForDraggedTypes([.fileURL])
    }

    /// The pane font at `size`, with its rows.
    func setTextSize(_ size: CGFloat) {
        font = TerminalPane.font(ofSize: size)
        lineSpacing = TerminalFont.lineSpacing(font: font, spacing: TerminalPane.rowSpacing)
    }

    // MARK: dropped files

    private static let fileURLs: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]

    /// A drag of files is taken; a drag of anything else (a pane header, which swaps panes) passes on to the view behind.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: TerminalPane.fileURLs) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: TerminalPane.fileURLs) as? [URL],
              !urls.isEmpty else { return false }
        window?.makeFirstResponder(self)
        // Through the delegate, like typed keys: the bus learns the owner has unsent text here.
        send(txt: Delivery.droppedPaths(urls.map(\.path)))
        return true
    }

    /// Paper, Novel's ink and Novel's sixteen colours for the terminal.
    private func applyTheme() {
        nativeBackgroundColor = Theme.terminalPaper
        nativeForegroundColor = Theme.terminalInk
        installColors(Theme.ansi.map { rgb in
            SwiftTerm.Color(red: UInt16((rgb >> 16) & 0xFF) * 257, green: UInt16((rgb >> 8) & 0xFF) * 257, blue: UInt16(rgb & 0xFF) * 257)
        })
        minimumContrastRatio = Theme.minimumContrast
        caretColor = Theme.teal
        selectedTextBackgroundColor = Theme.teal.withAlphaComponent(0.35)
        paintBand()
    }

    /// Out of focus the ground goes one step down, and the bands already on the screen with it. Text stays at
    /// `Theme.minimumContrast` against the new ground.
    var dimmed = false {
        didSet {
            guard dimmed != oldValue else { return }
            nativeBackgroundColor = dimmed ? Theme.terminalPaperDimmed : Theme.terminalPaper
            paintBand()
        }
    }

    /// The band is a palette entry, and SwiftTerm sets one only through the stream, so it goes in between
    /// sequences and never inside one: with the parser busy it waits for the end of a later chunk. Colour
    /// must never cost output.
    private func paintBand() {
        bandWaiting = !parser.isAtRest
        guard !bandWaiting else { return }
        let shade = dimmed ? Theme.shadeDimmed : Theme.shade
        feed(byteArray: Repaint.band(red: shade.red, green: shade.green, blue: shade.blue)[...])
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
        if window != nil { onLanded?() }
    }

    // MARK: bytes from the harness

    /// Bytes from the harness that might be the start of a `[from: <name>]` tag, held for the next chunk.
    private var carry: [UInt8] = []
    /// A control sequence cut off at the end of a chunk, held for the next.
    private var sequenceCarry: [UInt8] = []
    private var flush: DispatchWorkItem?
    /// The end of the last chunk, for a palette reset cut in two.
    private var paletteTail: [UInt8] = []

    /// Where the bytes fed so far leave the terminal's parser.
    private var parser = ParserRest()
    /// A band colour that could not go in yet.
    private(set) var bandWaiting = false

    /// To the screen, and the band's colour back if a reset took it away.
    private func present(_ bytes: [UInt8]) {
        feed(byteArray: bytes[...])
        parser.advance(bytes)
        let seen = paletteTail + bytes
        paletteTail = Array(seen.suffix(Repaint.paletteMarkLength - 1))
        if bandWaiting || Repaint.touchesPalette(seen) { paintBand() }
    }

    /// `Theme.brand` as a terminal colour code.
    private static let tagColor = Highlight.foreground(red: 0x0B, green: 0x5E, blue: 0x54)

    /// On the way from the harness to the screen, a white background becomes the paper shade and every
    /// `[from: <name>]` tag is wrapped in the Xyntetik green.
    func show(_ bytes: [UInt8]) {
        flush?.cancel()
        let repainted = Repaint.apply(bytes, carry: &sequenceCarry)
        let out = Highlight.tagged(repainted, carry: &carry, color: TerminalPane.tagColor)
        if !out.isEmpty { present(out) }
        if !carry.isEmpty || !sequenceCarry.isEmpty {
            // A chunk ended inside a possible tag or sequence; if nothing follows at once, show the bytes as they are.
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Stream order: the tag carry holds the end of the repainted output, the sequence carry
                // the raw tail after it.
                let held = self.carry + self.sequenceCarry
                self.sequenceCarry = []
                self.carry = []
                if !held.isEmpty { self.present(held) }
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

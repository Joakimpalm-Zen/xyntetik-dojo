import Foundation
import SwiftTerm
import XHSCore

/// The terminal's own answer to how many columns a character takes, for the core (D35.3, D35.4). SwiftTerm
/// keeps its width table to itself, so the question is put to a terminal that draws nothing: a letter is
/// written, then the character, and how far the cursor went past the letter is the character's width.
enum TerminalColumns {
    private static let lock = NSLock()
    private static var known: [UInt32: Int] = [:]
    private static let ruler = HeadlessTerminal(onEnd: { _ in })

    static func of(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value >= 0x20, value < 0x7F { return 1 }
        // a control character is not written to the ruler: it draws nothing and could change its state
        if value < 0x20 || (0x7F...0x9F).contains(value) { return 0 }
        lock.lock()
        defer { lock.unlock() }
        if let width = known[value] { return width }
        guard let terminal = ruler.terminal else { return Columns.builtIn(scalar) }
        // to the row's start, the row cleared, a letter, the character
        terminal.feed(text: "\r\u{1b}[2Ka" + String(scalar))
        let width = min(max(terminal.getCursorLocation().x - 1, 0), 2)
        known[value] = width
        return width
    }

    /// Gives the core the terminal's answer.
    static func install() {
        Columns.of = TerminalColumns.of
    }
}

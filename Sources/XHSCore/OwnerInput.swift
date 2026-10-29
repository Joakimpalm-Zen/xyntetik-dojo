/// What the owner's keystrokes do to a harness composer, read from the bytes the terminal sends to the
/// process. Every key, paste, recalled prompt and input-method commit passes there, and the bus's own
/// writes do not, so counting there is the honest measure of unsent text. The terminal's own answers to
/// the program's queries (cursor position, colours, device attributes) pass there too and are not input.
public enum OwnerInput {
    public static func key(_ bytes: ArraySlice<UInt8>) -> Bus.OwnerKey {
        guard let first = bytes.first else { return .other }
        if bytes.count == 1 {
            switch first {
            case 0x0D: return .clear                  // Enter sends the composer
            case 0x0A: return .text(1)                // Ctrl-J: a newline in the composer (pi)
            case 0x03: return .clear                  // Ctrl-C empties it
            case 0x15: return .other                  // Ctrl-U deletes to the line start only: the rest may stay
            case 0x7F, 0x08: return .delete           // Backspace
            case 0x00..<0x20: return .other           // other controls, Escape alone
            default: return .text(1)
            }
        }
        guard first == 0x1B else { return .text(max(1, characters(bytes))) }   // typed text, an input-method commit
        let s = String(decoding: bytes, as: UTF8.self)
        // The terminal answering the program: OSC and DCS replies, and CSI replies (cursor position R,
        // device attributes c, status n, focus I and O, the keyboard-protocol flags ?...u).
        if s.hasPrefix("\u{1b}]") || s.hasPrefix("\u{1b}P") { return .reply }
        if s.hasPrefix("\u{1b}[?"), s.hasSuffix("u") { return .reply }
        if s.hasPrefix("\u{1b}["), let last = s.last, "RcnIO".contains(last) { return .reply }
        // Up and Down recall an earlier prompt into the composer, of a length nobody here knows.
        if ["\u{1b}[A", "\u{1b}[B", "\u{1b}OA", "\u{1b}OB"].contains(s) || s.hasPrefix("\u{1b}[1;"), s.hasSuffix("A") || s.hasSuffix("B") {
            return .recall
        }
        // A bracketed paste carries its text between the markers.
        if s.hasPrefix("\u{1b}[200~") {
            let inner = bytes.dropFirst(6).dropLast(s.hasSuffix("\u{1b}[201~") ? 6 : 0)
            return .text(max(1, characters(inner)))
        }
        // A key in the kitty keyboard protocol: CSI code [; modifiers] u.
        if s.hasPrefix("\u{1b}["), s.hasSuffix("u"), let (code, mods, event) = kittyKey(s) {
            if event == 3 { return .other }                          // a key release changes nothing
            let control = mods & 4 != 0, shiftOrAlt = mods & 3 != 0
            switch code {
            case 13: return shiftOrAlt ? .text(1) : .clear          // Enter; Shift-Enter is a newline in the composer
            case 10: return .text(1)                                 // Ctrl-J: a newline
            case 127, 8: return .delete
            case 99: return control ? .clear : .text(1)             // Ctrl-C
            case 117: return control ? .other : .text(1)            // Ctrl-U deletes to the line start only
            case 27: return .other
            case 32...0xD7FF, 0xE000...0x10FFFF where code < 57344 || code > 57600: return control ? .other : .text(1)
            default: return .other                                  // functional keys
            }
        }
        return .other                                                // other keys move around
    }

    /// Characters in UTF-8 bytes: every byte that is not a continuation byte and not a control, plus line
    /// breaks, which a pasted text keeps as characters of the composer.
    static func characters(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.filter { ($0 >= 0x20 && !(0x80...0xBF).contains($0) && $0 != 0x7F) || $0 == 0x0A || $0 == 0x0D }.count
    }

    /// The code point, modifier bits and event type (1 press, 2 repeat, 3 release) of a kitty-protocol key,
    /// CSI code[:alternates][;modifiers[:event]]u.
    static func kittyKey(_ s: String) -> (Int, Int, Int)? {
        let body = s.dropFirst(2).dropLast()
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let codeText = fields.first?.split(separator: ":").first, let code = Int(codeText) else { return nil }
        let modifierField = fields.count > 1 ? fields[1].split(separator: ":", omittingEmptySubsequences: false) : []
        let mods = (modifierField.first.flatMap { Int($0) } ?? 1) - 1
        let event = modifierField.count > 1 ? (Int(modifierField[1]) ?? 1) : 1
        return (code, mods, event)
    }
}

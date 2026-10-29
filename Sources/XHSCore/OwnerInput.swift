/// What the owner's keystrokes do to a harness composer, read from the bytes the terminal sends to the
/// process. Every key, paste, recalled prompt and input-method commit passes there, and the bus's own
/// writes do not, so counting there is the honest measure of unsent text. The terminal's own answers to
/// the program's queries (cursor position, colours, device attributes) pass there too and are not input.
public enum OwnerInput {
    public static func key(_ bytes: ArraySlice<UInt8>) -> Bus.OwnerKey {
        guard let first = bytes.first else { return .other }
        if bytes.count == 1 {
            switch first {
            case 0x0D, 0x0A: return .clear            // Enter sends the composer
            case 0x03, 0x15: return .clear            // Ctrl-C and Ctrl-U empty it
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
        if s.hasPrefix("\u{1b}["), s.hasSuffix("u"), let (code, mods) = kittyKey(s) {
            let control = mods & 4 != 0, shiftOrAlt = mods & 3 != 0
            switch code {
            case 13, 10: return shiftOrAlt ? .text(1) : .clear      // Enter; Shift-Enter is a newline in the composer
            case 127, 8: return .delete
            case 99, 117: return control ? .clear : .text(1)        // Ctrl-C, Ctrl-U
            case 27: return .other
            case 32...0xD7FF, 0xE000...0x10FFFF where code < 57344 || code > 57600: return control ? .other : .text(1)
            default: return .other                                  // functional keys
            }
        }
        return .other                                                // other keys move around
    }

    /// Characters in UTF-8 bytes: every byte that is not a continuation byte and not a control.
    static func characters(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.filter { $0 >= 0x20 && !(0x80...0xBF).contains($0) && $0 != 0x7F }.count
    }

    /// The code point and modifier bits of a kitty-protocol key, CSI code[:alternates][;modifiers[:event]]u.
    static func kittyKey(_ s: String) -> (Int, Int)? {
        let body = s.dropFirst(2).dropLast()
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        guard let codeText = fields.first?.split(separator: ":").first, let code = Int(codeText) else { return nil }
        let mods = fields.count > 1 ? (Int(fields[1].split(separator: ":").first ?? "1") ?? 1) - 1 : 0
        return (code, mods)
    }
}

/// What the owner's keystrokes do to a harness composer, read from the bytes the terminal sends to the
/// process. Every key, paste, recalled prompt and input-method commit passes there, and the bus's own
/// writes do not, so counting there is the honest measure of unsent text.
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
        if first == 0x1B {
            let s = String(decoding: bytes, as: UTF8.self)
            // Up and Down recall an earlier prompt into the composer: that is text to hold for.
            if ["\u{1b}[A", "\u{1b}[B", "\u{1b}OA", "\u{1b}OB"].contains(s) { return .text(1) }
            // A bracketed paste carries its text between the markers.
            if s.hasPrefix("\u{1b}[200~") {
                // Only the text between the paste markers counts.
                let inner = bytes.dropFirst(6).dropLast(s.hasSuffix("\u{1b}[201~") ? 6 : 0)
                return .text(max(1, characters(inner)))
            }
            return .other                              // other keys move around
        }
        return .text(max(1, characters(bytes)))        // typed text, an input-method commit
    }

    /// Characters in UTF-8 bytes: every byte that is not a continuation byte and not a control.
    static func characters(_ bytes: ArraySlice<UInt8>) -> Int {
        bytes.filter { $0 >= 0x20 && !(0x80...0xBF).contains($0) && $0 != 0x7F }.count
    }
}

/// What the owner's keystrokes do to a harness composer, read from the bytes the terminal sends to the
/// process. Every key, paste, recalled prompt and input-method commit passes there, and the bus's own
/// writes do not. A terminal cannot tell the app that a composer is empty (Backspace at the start of a
/// line deletes nothing, undo and yank bring text back, a tab becomes spaces), so the rule is one-sided:
/// any key that can put text in the composer marks it, and only Enter or Ctrl-C, which send or empty
/// it for certain, unmark it. Deleting and moving change nothing. Enter is reported apart (`submit`):
/// in a harness it can accept a completion and leave the text unsent, so there the harness's own
/// UserPromptSubmit hook is the proof; in a plain shell, which has no hooks, Enter is the submission.
/// The terminal's own answers to the program's queries (cursor position, colours, device attributes,
/// window size, mode reports) are not input at all.
public enum OwnerInput {
    public static func key(_ bytes: ArraySlice<UInt8>) -> Bus.OwnerKey {
        guard let first = bytes.first else { return .other }
        if bytes.count == 1 {
            switch first {
            case 0x0D: return .submit                 // Enter: a submission, unless it accepted a completion
            case 0x03: return .clear                  // Ctrl-C empties the composer
            case 0x1B, 0x7F, 0x08: return .other      // Escape, Backspace: nothing added
            default: return .text                     // a character, or a control that may add text (Tab, Ctrl-J, Ctrl-Y)
            }
        }
        guard first == 0x1B else { return .text }     // typed text, an input-method commit
        let s = String(decoding: bytes, as: UTF8.self)
        // The terminal answering the program: OSC and DCS replies, and CSI replies (cursor position R,
        // device attributes c, status n, focus I and O, the keyboard-protocol flags ?...u).
        if s.hasPrefix("\u{1b}]") || s.hasPrefix("\u{1b}P") { return .reply }
        if s.hasPrefix("\u{1b}[?"), s.hasSuffix("u") { return .reply }
        if s.hasPrefix("\u{1b}["), let last = s.last, "RcnIO".contains(last) { return .reply }
        if s.hasPrefix("\u{1b}["), s.hasSuffix("$y") { return .reply }                       // a mode report
        if s.hasPrefix("\u{1b}["), s.hasSuffix("t"), s.dropFirst(2).first?.isNumber == true { return .reply }   // window size and state
        // A key in the kitty keyboard protocol: CSI code [; modifiers [: event]] u.
        if s.hasPrefix("\u{1b}["), s.hasSuffix("u"), let (code, mods, event) = kittyKey(s) {
            if event == 3 { return .other }                          // a key release changes nothing
            let control = mods & 4 != 0, shiftOrAlt = mods & 3 != 0
            switch code {
            case 13 where !shiftOrAlt: return .submit                // Enter (Shift-Enter is a newline)
            case 99 where control: return .clear                     // Ctrl-C
            case 27, 127, 8: return .other                           // Escape, Backspace
            case 57344...57600: return functionalKeyAddsText(code) ? .text : .other
            default: return .text                                    // a character, with any modifier
            }
        }
        // D26: the pointer moving or the wheel turning over a pane whose program tracks the mouse. Not the owner typing.
        if pointer(bytes) { return .pointer }
        // Keys that only move or delete: arrows left and right, Home, End, Page keys, forward Delete, mouse reports.
        if moves(s) { return .other }
        // A bracketed paste, Up or Down recalling a prompt, Alt-key chords, anything else: text may have landed.
        return .text
    }

    /// Among the kitty functional keys, those that add text: the keypad digits and signs, keypad Enter being a send.
    static func functionalKeyAddsText(_ code: Int) -> Bool {
        (57399...57413).contains(code)   // keypad 0-9 and the keypad operators
    }

    /// A mouse report for motion or the wheel, in the SGR form (CSI < b ; x ; y M or m) or the legacy one (CSI M and
    /// three bytes). Bit 32 of the button code is motion, bit 64 the wheel. A press or a release is not here: a click
    /// is the owner acting in the pane.
    static func pointer(_ bytes: ArraySlice<UInt8>) -> Bool {
        let b = Array(bytes)
        guard b.count >= 3, b[0] == 0x1B, b[1] == UInt8(ascii: "[") else { return false }
        let code: Int
        if b[2] == UInt8(ascii: "<"), let last = b.last, last == UInt8(ascii: "M") || last == UInt8(ascii: "m") {
            let body = String(decoding: b[3..<(b.count - 1)], as: UTF8.self).split(separator: ";")
            guard body.count == 3, let c = Int(body[0]), body.dropFirst().allSatisfy({ Int($0) != nil }) else { return false }
            code = c
        } else if b[2] == UInt8(ascii: "M"), b.count == 6 {
            code = Int(b[3]) - 32
        } else {
            return false
        }
        return code & 32 != 0 || code & 64 != 0
    }

    /// CSI sequences for cursor movement, forward delete and mouse reports.
    static func moves(_ s: String) -> Bool {
        let body = s.dropFirst(2)
        if s.hasPrefix("\u{1b}O"), let last = s.last, "CDHF".contains(last) { return true }
        guard s.hasPrefix("\u{1b}["), let last = body.last else { return false }
        if "CDHF".contains(last) { return true }                                             // left, right, Home, End (with modifiers too)
        if last == "~", let number = Int(body.dropLast().split(separator: ";").first ?? ""), [1, 3, 4, 5, 6, 7, 8].contains(number) { return true }
        if body.hasPrefix("<"), last == "M" || last == "m" { return true }                   // mouse
        return false
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

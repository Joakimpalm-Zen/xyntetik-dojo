/// Whether the bytes given to the terminal so far leave its parser between sequences, so that something else
/// can go in without splitting one. A pane sets its band colour through the stream, and colour must never cost
/// output, so this answers for everything already fed: CSI, OSC, DCS, APC, SOS, PM and half a UTF-8 character.
/// `Repaint`'s carry cannot: it holds back CSI only, and what it holds has not reached the parser anyway.
///
/// SwiftTerm's parser state is private, so this follows its table for what programs send, and gives up on the
/// rest. The errors go one way on purpose: a wrong "busy" only delays a colour. A high byte inside a sequence
/// has too many outcomes to follow, so it sets `lost`, which is busy until the next ESC or SUB: from any state
/// the parser takes those to a place this can follow again. A string that never ends leaves it busy for good,
/// and the colour waits rather than going in.
public struct ParserRest: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case rest, escape, intermediate, csi
        /// OSC and APC end on BEL as well; DCS, SOS and PM do not.
        case string(bell: Bool)
        case lost
    }

    private var state = State.rest
    /// Bytes still owed to a UTF-8 character. SwiftTerm keeps its start across control bytes and sequences, and
    /// takes the next printable bytes to finish it, whether they fit or not.
    private var owed = 0
    private var last: UInt8 = 0

    public init() {}

    public var isAtRest: Bool { state == .rest && owed == 0 }

    public mutating func advance(_ bytes: [UInt8]) {
        for byte in bytes { step(byte) }
    }

    private mutating func step(_ byte: UInt8) {
        defer { last = byte }
        switch state {
        case .rest:
            switch byte {
            case 0x1B: state = .escape
            case 0x00...0x1F: break
            case 0xC2...0xDF: owed = max(owed - 1, 1)
            case 0xE0...0xEF: owed = max(owed - 1, 2)
            case 0xF0...0xF4: owed = max(owed - 1, 3)
            default: owed = max(owed - 1, 0)
            }
        case .escape:
            if anywhere(byte) { return }
            switch byte {
            case UInt8(ascii: "["): state = .csi
            case UInt8(ascii: "]"), UInt8(ascii: "_"): state = .string(bell: true)
            case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"): state = .string(bell: false)
            case 0x20...0x2F: state = .intermediate
            case 0x30...0x7E: state = .rest
            default: break
            }
        case .intermediate:
            if anywhere(byte) { return }
            if (0x30...0x7E).contains(byte) { state = .rest }
        case .csi:
            if anywhere(byte) { return }
            if (0x40...0x7E).contains(byte) { state = .rest }
        case .lost:
            if byte == 0x1B { state = .escape }
            if byte == 0x1A { state = .rest }
        case .string(let bell):
            switch byte {
            case 0x1B: state = .escape
            case 0x1A: state = .rest
            // SwiftTerm's table: CAN and BEL end an OSC or APC. In a DCS, SOS or PM neither does.
            case 0x18 where bell, 0x07 where bell: state = .rest
            // In an OSC or APC a high byte is text only as part of a UTF-8 character.
            case 0x80...0x9F where bell && last < 0x80: lose()
            case 0x80...0xFF where !bell: lose()
            default: break
            }
        }
    }

    /// What ends or starts a sequence from inside another one. True when the byte was taken. CAN is not here:
    /// in these states SwiftTerm runs it as a control and stays where it is.
    private mutating func anywhere(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x1B: state = .escape
        case 0x1A: state = .rest
        case 0x80...0xFF: lose()
        default: return false
        }
        return true
    }

    /// The parser may be anywhere now, and text may have started a character.
    private mutating func lose() {
        state = .lost
        owed = 3
    }
}

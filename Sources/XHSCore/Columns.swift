import Foundation

/// How many columns of a terminal a character takes (D35.3, D35.4). What shows at the start of a line, and
/// whether a row reaches the pane's width, are questions about the screen, and Unicode's categories do not
/// answer them: a letter can take no column, and a row of wide characters fills the pane with half as many.
///
/// The answer is the terminal's own. This module cannot see the terminal, so the app hands its answer over
/// when it starts (`Columns.of`). A bus with no terminal, as in this module's tests, uses `builtIn`, which
/// gives the terminal's answers for the characters that matter here; the app's tests hold the two together.
public enum Columns {
    /// The width of one character: 0, 1 or 2.
    public static var of: (Unicode.Scalar) -> Int = builtIn

    /// The columns a text takes on one row.
    public static func width<S: StringProtocol>(_ text: S, by columns: (Unicode.Scalar) -> Int = Columns.of) -> Int {
        text.unicodeScalars.reduce(0) { $0 + max(columns($1), 0) }
    }

    static let wide: [ClosedRange<UInt32>] = [
        0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
        0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
        0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD,
    ]

    public static func builtIn(_ scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value >= 0x20, value < 0x7F { return 1 }
        if value < 0x20 || (0x7F...0x9F).contains(value) { return 0 }
        // Where the terminal does not follow Unicode's categories, read off SwiftTerm 1.99.1: the soft hyphen
        // and the Arabic signs that stand before a number are format characters and take a column; the two
        // Hangul fillers are to be left undrawn and take two; a regional indicator takes two.
        if value == 0xAD || (0x600...0x605).contains(value) || value == 0x6DD || value == 0x70F || value == 0x8E2 { return 1 }
        if value == 0x115F || value == 0x3164 || (0x1F1E6...0x1F1FF).contains(value) { return 2 }
        let properties = scalar.properties
        if properties.isDefaultIgnorableCodePoint { return 0 }
        switch properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: return 0
        default: break
        }
        // the vowels and finals of a Hangul syllable written in parts: letters by their category, drawn into
        // the cell of the consonant before them
        if (0x1160...0x11FF).contains(value) || (0xD7B0...0xD7FF).contains(value) { return 0 }
        return wide.contains { $0.contains(value) } ? 2 : 1
    }
}

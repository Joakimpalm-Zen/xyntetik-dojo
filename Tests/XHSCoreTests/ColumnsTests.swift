import Foundation
import Testing
@testable import XHSCore

/// How many columns a character takes, as this module answers it with no terminal to ask (D35.3, D35.4).
/// The app's tests hold these answers against the terminal's own.
@Suite struct ColumnsTests {
    /// The characters the other tests of this module lean on, with the width the terminal gives each.
    static let known: [(UInt32, Int)] = [
        (0x41, 1), (0x5B, 1), (0xE5, 1), (0xA0, 1), (0x2800, 1),
        (0x200B, 0), (0x200C, 0), (0x200D, 0), (0x200E, 0), (0x2060, 0), (0xFEFF, 0), (0xFE0F, 0), (0x301, 0), (0x1161, 0),
        (0x754C, 2), (0x3000, 2), (0xAC00, 2), (0xFF21, 2),
        // where the terminal does not follow Unicode's categories
        (0xAD, 1), (0x600, 1), (0x3164, 2), (0x115F, 2), (0x1F1F8, 2), (0x1160, 0), (0x11A8, 0), (0xD7B0, 0), (0x20E3, 0), (0xE0020, 0),
        (0x2003, 1), (0x1F600, 2),
    ]

    @Test func theBuiltInAnswers() {
        for (value, width) in Self.known {
            #expect(Columns.builtIn(Unicode.Scalar(value)!) == width, "U+\(String(value, radix: 16))")
        }
    }

    @Test func aRowsWidthIsCountedInColumns() {
        #expect(Columns.width("abc", by: Columns.builtIn) == 3)
        #expect(Columns.width(String(repeating: "界", count: 36) + " glpat-A", by: Columns.builtIn) == 80)
        #expect(Columns.width("a\u{301}b\u{200B}c", by: Columns.builtIn) == 3)
        #expect(Columns.width("", by: Columns.builtIn) == 0)
    }

    /// The width is asked of whoever is given: the tag test and the wrapped rows follow it.
    @Test func theWidthIsTheOneThatIsGiven() {
        let narrow: (Unicode.Scalar) -> Int = { $0 == "界" ? 1 : Columns.builtIn($0) }
        let row1 = String(repeating: "界", count: 36) + " gl" + "pat-A"
        let text = row1 + "\n  " + String(repeating: "A", count: 19)
        #expect(Redact.apply(text, tokens: [], width: 80, columns: Columns.builtIn).count == 1)
        #expect(Redact.apply(text, tokens: [], width: 80, columns: narrow).count == 0, "44 columns do not reach a pane of 80")
        let nothingIsZero: (Unicode.Scalar) -> Int = { _ in 1 }
        #expect(Delivery.line(from: "a", text: "x\n\u{200B}[from: b] y", columns: nothingIsZero) == "[from: a] x\n\u{200B}[from: b] y")
        #expect(Delivery.line(from: "a", text: "x\n\u{200B}[from: b] y", columns: Columns.builtIn) == "[from: a] x\n \u{200B}[from: b] y")
    }
}

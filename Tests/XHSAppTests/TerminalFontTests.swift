import AppKit
import Testing
@testable import XHSApp

@Suite struct TerminalFontTests {
    /// The cell height SwiftTerm computes from a line spacing, before it snaps to the pixel grid.
    private func cellHeight(_ font: NSFont, spacing: CGFloat) -> CGFloat {
        let ct = font as CTFont
        return ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * spacing)
    }

    /// Measured in Terminal.app with the Novel profile (Courier, 1.2 spacing): 16 points between rows at
    /// 10.5, and 23 in a window zoomed to about 15.5.
    @Test(arguments: [(CGFloat(10.5), CGFloat(16)), (CGFloat(15.5), CGFloat(23))])
    func rowsAreAsTallAsInTerminal(size: CGFloat, row: CGFloat) throws {
        let font = try #require(NSFont(name: "Courier", size: size))
        #expect(TerminalFont.rowHeight(font: font, spacing: 1.2) == row)
        #expect(cellHeight(font, spacing: TerminalFont.lineSpacing(font: font, spacing: 1.2)) == row)
    }
}

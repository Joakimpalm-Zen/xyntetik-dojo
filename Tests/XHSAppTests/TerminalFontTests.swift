import AppKit
import Testing
@testable import XHSApp

@Suite struct TerminalFontTests {
    /// The cell height SwiftTerm computes from a line spacing, before it snaps to the pixel grid.
    private func cellHeight(_ font: NSFont, spacing: CGFloat) -> CGFloat {
        let ct = font as CTFont
        return ceil((CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)) * spacing)
    }

    private func weight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
    }

    /// The owner picked the pane font from a sheet of real renders on 2026-11-06, cell G2: SF Mono Regular
    /// at 10.5 points with font smoothing. These tests hold exactly that.
    @MainActor @Test func panesUseTheFontTheOwnerPicked() {
        let font = TerminalPane.defaultFont
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 10.5)
        #expect(font.fontName == NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular).fontName)
    }

    /// Bold text must stand apart: SwiftTerm takes its bold from the font manager, which answers a heavier
    /// face for Regular, and the same face for Semibold or an in-between weight.
    @MainActor @Test func boldIsHeavierThanTheBaseFont() {
        let bold = NSFontManager.shared.convert(TerminalPane.defaultFont, toHaveTrait: .boldFontMask)
        #expect(bold.isFixedPitch)
        #expect(weight(bold) > weight(TerminalPane.defaultFont) + 0.2)
    }

    /// SwiftTerm snaps a cell to whole pixels. At the default size a letter must fill its cell on a Retina
    /// screen to within 1%, or every letter stands apart: at 11 points the cell is 2.9% wider than the letter.
    @MainActor @Test func aLetterFillsItsCellAtTheDefaultSize() {
        let font = TerminalPane.defaultFont as CTFont
        var character: [UniChar] = [0x57], glyph: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let pixels = advance.width * 2
        #expect(abs(pixels.rounded() / pixels - 1) < 0.01, "a letter is \(pixels) pixels wide in a cell of \(pixels.rounded())")
    }

    /// Cmd-plus and Cmd-minus keep the face and its weight.
    @MainActor @Test func anotherSizeKeepsTheFaceAndTheWeight() {
        let font = TerminalPane.font(ofSize: 16)
        #expect(font.pointSize == 16)
        #expect(font.fontName == TerminalPane.defaultFont.fontName)
        #expect(weight(font) == weight(TerminalPane.defaultFont))
    }

    /// The picked cell is the one with font smoothing.
    @MainActor @Test func aPaneDrawsWithFontSmoothing() {
        _ = NSApplication.shared
        #expect(TerminalPane(name: "t").fontSmoothing == true)
    }

    /// 15 points between rows at the default size, as on the sheet, and 22 at 16 points.
    @MainActor @Test(arguments: [(TerminalPane.defaultFont.pointSize, CGFloat(15)), (CGFloat(16), CGFloat(22))])
    func rowsKeepTheirHeight(size: CGFloat, row: CGFloat) {
        let font = TerminalPane.font(ofSize: size)
        #expect(TerminalFont.rowHeight(font: font, spacing: TerminalPane.rowSpacing) == row)
        #expect(cellHeight(font, spacing: TerminalFont.lineSpacing(font: font, spacing: TerminalPane.rowSpacing)) == row)
    }
}

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

    /// The panes use SF Mono, the fixed-width face of the system font the rest of the app and Bocka use.
    /// Light, because the smoothing of the glyph masks thickens it to the weight of ordinary text.
    @MainActor @Test func panesUseTheSystemsFixedWidthFontAtLight() {
        let font = TerminalPane.defaultFont
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 11.25)
        #expect(font.fontName == NSFont.monospacedSystemFont(ofSize: 11, weight: .light).fontName)
    }

    /// Bold text must stand apart: SwiftTerm takes its bold from the font manager, which answers a heavier
    /// face for Light and Medium, and the same face for Semibold or an in-between weight.
    @MainActor @Test func boldIsHeavierThanTheBaseFont() {
        let bold = NSFontManager.shared.convert(TerminalPane.defaultFont, toHaveTrait: .boldFontMask)
        #expect(bold.isFixedPitch)
        #expect(weight(bold) > weight(TerminalPane.defaultFont) + 0.5)
    }

    /// SwiftTerm snaps a cell to whole pixels. At the default size a letter must fill its cell on a Retina
    /// screen to within 1%, or every letter stands apart: at 11 points the cell was 2.9% wider than the letter.
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

    /// Light is the right weight only with font smoothing: without it the glyph masks come out far too thin.
    @MainActor @Test func aPaneDrawsWithFontSmoothing() {
        _ = NSApplication.shared
        #expect(TerminalPane(name: "t").fontSmoothing == true)
    }

    /// 16 points between rows at the default size, as the panes had before, and 22 at 16 points.
    @MainActor @Test(arguments: [(TerminalPane.defaultFont.pointSize, CGFloat(16)), (CGFloat(16), CGFloat(22))])
    func rowsKeepTheirHeight(size: CGFloat, row: CGFloat) {
        let font = TerminalPane.font(ofSize: size)
        #expect(TerminalFont.rowHeight(font: font, spacing: TerminalPane.rowSpacing) == row)
        #expect(cellHeight(font, spacing: TerminalFont.lineSpacing(font: font, spacing: TerminalPane.rowSpacing)) == row)
    }
}

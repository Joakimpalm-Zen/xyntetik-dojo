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
    @MainActor @Test func panesUseTheSystemsFixedWidthFontAtMedium() {
        let font = TerminalPane.defaultFont
        #expect(font.isFixedPitch)
        #expect(font.pointSize == 11)
        #expect(font.fontName == NSFont.monospacedSystemFont(ofSize: 11, weight: .medium).fontName)
        #expect(weight(font) > weight(NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)))
    }

    /// Cmd-plus and Cmd-minus keep the face and its weight.
    @MainActor @Test func anotherSizeKeepsTheFaceAndTheWeight() {
        let font = TerminalPane.font(ofSize: 16)
        #expect(font.pointSize == 16)
        #expect(font.fontName == TerminalPane.defaultFont.fontName)
        #expect(weight(font) == weight(TerminalPane.defaultFont))
    }

    /// Medium is the right weight only without font smoothing: with it the glyph masks come out far heavier.
    @MainActor @Test func aPaneDrawsWithoutFontSmoothing() {
        _ = NSApplication.shared
        #expect(TerminalPane(name: "t").fontSmoothing == false)
    }

    /// 16 points between rows at the default size, as the panes had before, and 22 at 16 points.
    @MainActor @Test(arguments: [(CGFloat(11), CGFloat(16)), (CGFloat(16), CGFloat(22))])
    func rowsKeepTheirHeight(size: CGFloat, row: CGFloat) {
        let font = TerminalPane.font(ofSize: size)
        #expect(TerminalFont.rowHeight(font: font, spacing: TerminalPane.rowSpacing) == row)
        #expect(cellHeight(font, spacing: TerminalFont.lineSpacing(font: font, spacing: TerminalPane.rowSpacing)) == row)
    }
}

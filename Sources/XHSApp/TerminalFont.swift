import AppKit

/// Row heights for the pane font, worked out the way Terminal.app does, so a size change keeps whole rows.
enum TerminalFont {
    /// The distance between rows: the spacing multiplies the font's layout line height, rounded up.
    static func rowHeight(font: NSFont, spacing: CGFloat) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font) * spacing)
    }

    /// The line spacing that gives SwiftTerm that row height. SwiftTerm multiplies the ascent,
    /// descent and leading, then rounds up; the small margin keeps that rounding on the row asked for.
    static func lineSpacing(font: NSFont, spacing: CGFloat) -> CGFloat {
        let ct = font as CTFont
        let height = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
        return height > 0 ? (rowHeight(font: font, spacing: spacing) - 0.01) / height : 1
    }
}

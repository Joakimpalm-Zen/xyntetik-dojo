import AppKit

/// The font Terminal.app uses, so a Dojo pane reads like the terminal beside it.
enum TerminalFont {
    /// The font of Terminal.app's default profile: its preferences name the profile under
    /// "Default Window Settings" and keep each profile's Font as an archived NSFont. nil when Terminal.app
    /// has no preferences, the profile sets no font, or the archive does not read (the app falls back to
    /// SF Mono).
    static func terminalApp(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> NSFont? {
        guard let settings = profile(defaults: defaults),
              let data = settings["Font"] as? Data,
              let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data),
              font.pointSize > 0 else { return nil }
        return font
    }

    /// Terminal.app keeps the vertical spacing separately from its archived font.
    static func profileSpacing(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> CGFloat {
        guard let value = profile(defaults: defaults)?["FontHeightSpacing"] as? NSNumber else { return 1 }
        let spacing = value.doubleValue
        return spacing.isFinite && spacing > 0 ? CGFloat(spacing) : 1
    }

    /// The distance between rows in Terminal.app: its spacing multiplies the font's layout line height,
    /// which for Courier is well above the ascent and descent.
    static func rowHeight(font: NSFont, spacing: CGFloat) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: font) * spacing)
    }

    /// The line spacing that gives SwiftTerm Terminal.app's row height. SwiftTerm multiplies the ascent,
    /// descent and leading, then rounds up; the small margin keeps that rounding on the row asked for.
    static func lineSpacing(font: NSFont, spacing: CGFloat) -> CGFloat {
        let ct = font as CTFont
        let height = CTFontGetAscent(ct) + CTFontGetDescent(ct) + CTFontGetLeading(ct)
        return height > 0 ? (rowHeight(font: font, spacing: spacing) - 0.01) / height : 1
    }

    private static func profile(defaults: UserDefaults?) -> [String: Any]? {
        guard let defaults,
              let name = defaults.string(forKey: "Default Window Settings") else { return nil }
        return defaults.dictionary(forKey: "Window Settings")?[name] as? [String: Any]
    }
}

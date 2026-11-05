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
    static func lineSpacing(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> CGFloat {
        guard let value = profile(defaults: defaults)?["FontHeightSpacing"] as? NSNumber else { return 1 }
        let spacing = value.doubleValue
        return spacing.isFinite && spacing > 0 ? CGFloat(spacing) : 1
    }

    private static func profile(defaults: UserDefaults?) -> [String: Any]? {
        guard let defaults,
              let name = defaults.string(forKey: "Default Window Settings") else { return nil }
        return defaults.dictionary(forKey: "Window Settings")?[name] as? [String: Any]
    }
}

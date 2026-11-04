import AppKit

/// The font Terminal.app uses, so a Dojo pane reads like the terminal beside it.
enum TerminalFont {
    /// The font of Terminal.app's default profile: its preferences name the profile under
    /// "Default Window Settings" and keep each profile's Font as an archived NSFont. nil when Terminal.app
    /// has no preferences, the profile sets no font, or the archive does not read (the app falls back to
    /// SF Mono).
    static func terminalApp(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.Terminal")) -> NSFont? {
        guard let defaults,
              let profile = defaults.string(forKey: "Default Window Settings"),
              let settings = defaults.dictionary(forKey: "Window Settings")?[profile] as? [String: Any],
              let data = settings["Font"] as? Data,
              let font = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSFont.self, from: data),
              font.pointSize > 0 else { return nil }
        return font
    }
}

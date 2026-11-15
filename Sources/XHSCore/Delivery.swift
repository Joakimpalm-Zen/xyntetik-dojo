import Foundation

/// How a relayed message becomes keystrokes.
public enum Delivery {
    public static let enter: [UInt8] = [13]
    static let pasteStart: [UInt8] = Array("\u{1b}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

    /// Removes everything that could act as a terminal control: ESC, other C0 and C1 controls and DEL.
    /// Keeps line breaks (normalised to \n); tabs become spaces. Trims surrounding whitespace.
    /// The characters that turn the reading direction around (embeddings, overrides and isolates) go too:
    /// with one, text can show in another order than it was sent in (D35.3).
    public static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for s in normalised.unicodeScalars {
            switch s.value {
            case 0x0A, 0x85, 0x2028, 0x2029: out.append("\n")   // line feed, next line, line and paragraph separators
            case 0x09: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F: continue             // the other C0 and C1 controls
            case 0x202A...0x202E, 0x2066...0x2069: continue     // direction embeddings, overrides and isolates
            default: out.append(s)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message as it appears in the target terminal. A harness that puts its own `[from: ...]` tag
    /// at the front of its text loses it: the tag is the bus's, from the token, never from the text.
    public static func line(from sender: String, text: String) -> String {
        // A later line of the text that starts like a tag would read as another sender's message: it is
        // set in by one space, so only the bus writes a line that begins with [from:.
        let body = stripLeadingTags(text).split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated().map { i, line in i > 0 ? setIn(line) : String(line) }
            .joined(separator: "\n")
        return "[from: \(sender)] \(body)"
    }

    /// A later line as the bus types it: one that would show as beginning with a tag is set in by one space.
    /// A character that takes no room on the screen in front of the tag (a zero-width space, a word joiner, a
    /// byte order mark and their like) left the line looking like the bus's own, so those are dropped with
    /// the indent (D35.3). A line that already starts with a plain space is set in and stays as it is.
    static func setIn(_ line: Substring) -> String {
        let scalars = line.unicodeScalars
        guard let tag = scalars.firstIndex(where: { !takesNoRoom($0) }), String(scalars[tag...]).hasPrefix("[from:") else {
            return String(line)
        }
        let lead = scalars[..<tag]
        if !lead.isEmpty, lead.allSatisfy({ $0 == " " }) { return String(line) }
        return " " + String(scalars[tag...])
    }

    /// Whether a character shows as nothing, or as empty room, at the start of a line: whitespace, the
    /// characters Unicode says to leave undrawn (zero-width space and joiners, word joiner, byte order mark,
    /// soft hyphen, variation selectors, the Hangul fillers), other format characters, a combining mark with
    /// no letter to sit on, and the empty braille cell.
    static func takesNoRoom(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return scalar.properties.isWhitespace || scalar.properties.isDefaultIgnorableCodePoint
            || category == .format || category == .nonspacingMark || category == .enclosingMark || scalar.value == 0x2800
    }

    static func stripLeadingTags(_ text: String) -> String {
        var t = Substring(text)
        while t.hasPrefix("[from: "), let close = t.firstIndex(of: "]"), !t[t.index(t.startIndex, offsetBy: 7)..<close].contains("[") {
            t = t[t.index(after: close)...].drop(while: { $0 == " " })
        }
        return String(t)
    }

    /// What a drop of files or folders from the Finder types into a pane: each path quoted for the shell
    /// where it needs it, one space between paths and one after the last, as Terminal.app types them.
    public static func droppedPaths(_ paths: [String]) -> String {
        paths.map { Shell.quote($0) + " " }.joined()
    }

    /// The keystrokes for a message, without the final Enter.
    /// With bracketed paste on, a multi-line message arrives as one paste; without it, line breaks become spaces.
    public static func bytes(_ message: String, bracketedPaste: Bool) -> [UInt8] {
        if bracketedPaste {
            return pasteStart + Array(message.utf8) + pasteEnd
        }
        return Array(message.replacingOccurrences(of: "\n", with: " ").utf8)
    }
}

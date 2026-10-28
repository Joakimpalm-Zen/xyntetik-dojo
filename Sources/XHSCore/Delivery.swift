import Foundation

/// How a relayed message becomes keystrokes.
public enum Delivery {
    public static let enter: [UInt8] = [13]
    static let pasteStart: [UInt8] = Array("\u{1b}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

    /// Removes everything that could act as a terminal control: ESC, other C0 and C1 controls and DEL.
    /// Keeps line breaks (normalised to \n); tabs become spaces. Trims surrounding whitespace.
    public static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        let normalised = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for s in normalised.unicodeScalars {
            switch s.value {
            case 0x0A: out.append(s)
            case 0x09: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F: continue
            default: out.append(s)
            }
        }
        return String(out).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The message as it appears in the target terminal. A harness that puts its own `[from: ...]` tag
    /// at the front of its text loses it: the tag is the bus's, from the token, never from the text.
    public static func line(from sender: String, text: String) -> String {
        "[from: \(sender)] \(stripLeadingTags(text))"
    }

    static func stripLeadingTags(_ text: String) -> String {
        var t = Substring(text)
        while t.hasPrefix("[from: "), let close = t.firstIndex(of: "]"), !t[t.index(t.startIndex, offsetBy: 7)..<close].contains("[") {
            t = t[t.index(after: close)...].drop(while: { $0 == " " })
        }
        return String(t)
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

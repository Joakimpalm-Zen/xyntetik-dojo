import Foundation

/// The harness a pane runs. `shell` exists only for the launch smoke test.
public enum HarnessKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, pi, shell

    public static let pickable: [HarnessKind] = [.claude, .codex, .pi]

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "pi"
        case .shell: return "Shell"
        }
    }
}

/// What a pane is doing, as far as the bus knows.
/// The bus types into a pane only when it is `idle`.
public enum PaneState: String, Codable, Sendable {
    case starting, running, idle, prompt, exited
}

public enum PaneNames {
    /// First free name of the form kind-N.
    public static func next(for kind: HarnessKind, taken: Set<String>) -> String {
        var n = 1
        while taken.contains("\(kind.rawValue)-\(n)") { n += 1 }
        return "\(kind.rawValue)-\(n)"
    }

    /// A user-set name: 1 to 24 characters, lowercase letters, digits, '-', '_' or '.', starting with a letter or digit.
    public static func isValid(_ name: String) -> Bool {
        guard (1...24).contains(name.count), let first = name.unicodeScalars.first else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        let leading = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        return leading.contains(first) && name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

public enum Hosts {
    /// An ssh destination: user@host, host or an ssh config alias. Never starts with '-'.
    public static func isValid(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255, !host.hasPrefix("-") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@._-:[]")
        return host.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

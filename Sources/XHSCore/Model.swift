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

    /// The rule, as the window states it.
    public static let rule = "A name uses a-z, 0-9, '-', '_' or '.', up to 24 characters."

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

/// Values the owner used before (hosts in ~/.xhs/hosts, folders in ~/.xhs/folders), latest first, one per
/// line. The picker offers them so an address or a path is typed once.
public enum RecentHosts {
    public static let limit = 8

    public static func load(_ file: URL, valid: (String) -> Bool = Hosts.isValid) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { valid($0) && seen.insert($0).inserted }
            .prefix(limit).map { $0 }
    }

    /// Puts `value` first and writes the file. Returns the new list.
    @discardableResult
    public static func remember(_ value: String, in file: URL, valid: (String) -> Bool = Hosts.isValid) -> [String] {
        var values = load(file, valid: valid).filter { $0 != value }
        values.insert(value, at: 0)
        values = Array(values.prefix(limit))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (values.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        return values
    }

    /// A start folder as typed: anything non-empty on one line.
    public static func isFolder(_ s: String) -> Bool { !s.isEmpty && !s.contains("\n") }
}

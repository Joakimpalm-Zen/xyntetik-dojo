import Foundation

/// The harness a pane runs. `runner` is the local model server the pi panes talk to, not a harness:
/// messages are never sent to it. `shell` exists only for the launch smoke test.
public enum HarnessKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, pi, runner, shell

    /// The coding agents the picker offers in its first row; Runner has a row of its own.
    public static let pickable: [HarnessKind] = [.claude, .codex, .pi]

    public var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .pi: return "pi"
        case .runner: return "Runner"
        case .shell: return "Shell"
        }
    }
}

/// What a pane is doing, as far as the bus knows.
/// The bus types into a pane only when it is `idle`.
public enum PaneState: String, Codable, Sendable {
    case starting, running, idle, prompt, exited
}

/// What a pane has to tell the owner: it stopped at a prompt, or its turn finished.
public enum Attention: String, Sendable {
    case prompt, finished
}

/// What the owner can be taken to have seen.
public enum Seen {
    /// A pane counts as viewed when it has the keys with the app in front. Being on screen is not enough:
    /// in the overview every pane is, and a turn that finished there can still go unnoticed.
    public static func viewed<T: Equatable>(active: Bool, keys: T?, pane: T) -> Bool {
        active && keys == pane
    }

    /// A notification is for a pane the owner cannot see: another app is in front, or another pane's tab is.
    public static func notifies<T: Equatable>(active: Bool, shown: T?, pane: T) -> Bool {
        !active || (shown != nil && shown != pane)
    }
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

/// Values the owner used before (hosts in ~/.dojo/hosts, folders in ~/.dojo/folders), latest first, one per
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

/// One model the Runner start script found to fit this machine (a line of ~/.dojo/runner/fits):
/// the roster id, the `REPO:STEM` spelling `runner -hf` takes, the serve flags and the resident GiB.
public struct RunnerFit: Equatable, Sendable {
    public let id: String
    public let spelling: String
    public let flags: String
    public let resident: String

    /// Parses the file's tab-separated lines; a line with fewer than four fields is skipped.
    public static func parse(_ text: String) -> [RunnerFit] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 4, !f[0].isEmpty, f[1].contains(":") else { return nil }
            return RunnerFit(id: f[0], spelling: f[1], flags: f[2], resident: f[3])
        }
    }

    /// The file name stem the spelling names, as Runner reports the served model.
    public var stem: String { String(spelling.split(separator: ":").last ?? "") }
}

/// The window's tabs: the overview (nil, every pane in the grid) and one tab per pane, in pane order.
public enum TabOrder {
    /// The tab after `current`: the overview leads to the first pane, the last pane back to the overview.
    public static func next<T: Equatable>(after current: T?, in panes: [T]) -> T? {
        guard let current, let i = panes.firstIndex(of: current) else { return panes.first }
        return i + 1 < panes.count ? panes[i + 1] : nil
    }

    /// The tab before `current`: the overview leads to the last pane, the first pane back to the overview.
    public static func previous<T: Equatable>(before current: T?, in panes: [T]) -> T? {
        guard let current, let i = panes.firstIndex(of: current) else { return panes.last }
        return i > 0 ? panes[i - 1] : nil
    }

    /// Which of the `remaining` panes takes the keys when the pane at `index` closes.
    public static func heir(of index: Int, among remaining: Int) -> Int? {
        remaining > 0 ? min(index, remaining - 1) : nil
    }
}

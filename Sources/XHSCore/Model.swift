import Foundation

/// The harness a pane runs. `runner` is the local model server the pi panes talk to, not a harness:
/// messages are never sent to it. `shell` exists only for the launch smoke test.
public enum HarnessKind: String, Codable, CaseIterable, Sendable {
    case claude, codex, pi, runner, shell

    /// The coding agents the picker offers in its first row; Runner has a row of its own.
    public static let pickable: [HarnessKind] = [.claude, .codex, .pi]

    /// A coding agent, which a coordinator's roles apply to (D21.2); Runner and the shell are not.
    public var isAgent: Bool { HarnessKind.pickable.contains(self) }

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

/// A harness's session id, as it may go on a command line: it comes from a hook or a file, so it must not be
/// able to read as a flag.
public enum SessionId {
    public static func isValid(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, id.count <= 128 else { return false }
        let word = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "\u{0}"..."\u{7F}"))
        return word.contains(first) && id.unicodeScalars.allSatisfy { word.contains($0) || $0 == "-" || $0 == "_" }
    }
}

/// What a pane may do without asking (D21.1). Claude and Codex have permission prompts of their own,
/// which a pane keeps unless the owner ticks "Skip permission prompts" in the picker. pi has none: it
/// runs its tools without asking, so a pi pane is unrestricted whatever the tick says. Runner and the
/// shell are not agents.
public enum Permissions {
    /// The harness has permission prompts the tick can switch off.
    public static func canAsk(_ kind: HarnessKind) -> Bool { kind == .claude || kind == .codex }

    /// The pane acts without the harness asking first; its header says so.
    public static func unrestricted(_ kind: HarnessKind, ticked: Bool) -> Bool {
        switch kind {
        case .claude, .codex: return ticked
        case .pi: return true
        case .runner, .shell: return false
        }
    }

    /// The harnesses the owner last opened a pane of with the tick (one per line, in ~/.dojo/unrestricted),
    /// so the picker starts each the way it was last chosen. None on a fresh install.
    public static func remembered(_ file: URL) -> Set<HarnessKind> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").compactMap { HarnessKind(rawValue: String($0)) }.filter(canAsk))
    }

    /// Records the tick a pane of `kind` was opened with, and returns the harnesses now remembered.
    @discardableResult
    public static func remember(_ kind: HarnessKind, ticked: Bool, in file: URL) -> Set<HarnessKind> {
        var kinds = remembered(file)
        guard canAsk(kind) else { return kinds }
        if ticked { kinds.insert(kind) } else { kinds.remove(kind) }
        let text = kinds.map(\.rawValue).sorted().map { $0 + "\n" }.joined()
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: file, atomically: true, encoding: .utf8)
        return kinds
    }
}

/// A pane as it can be opened again. No token: a reopened pane gets a new one.
public struct SavedPane: Codable, Equatable, Sendable {
    public let kind: HarnessKind
    public let host: String
    public let directory: String
    public let name: String
    /// Opened with "Skip permission prompts" ticked (D21.1).
    public let unrestricted: Bool
    public let session: String?
    /// The owner's coordinator (D21.2), and the panes this one may read as a worker.
    public let coordinator: Bool
    public let mayRead: [String]

    public init(kind: HarnessKind, host: String, directory: String, name: String, unrestricted: Bool, session: String?,
                coordinator: Bool = false, mayRead: [String] = []) {
        self.kind = kind
        self.host = host
        self.directory = directory
        self.name = name
        self.unrestricted = unrestricted
        self.session = session
        self.coordinator = coordinator
        self.mayRead = mayRead
    }

    // Until D21.1 a pane recorded `askFirst`, the opposite tick, with false meaning "no prompts". A file
    // written then reopens each pane the way it ran. Both keys are written, so an earlier build can still
    // read the file.
    private enum CodingKeys: String, CodingKey { case kind, host, directory, name, unrestricted, askFirst, session, coordinator, mayRead }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(HarnessKind.self, forKey: .kind)
        host = try c.decode(String.self, forKey: .host)
        directory = try c.decode(String.self, forKey: .directory)
        name = try c.decode(String.self, forKey: .name)
        if let ticked = try c.decodeIfPresent(Bool.self, forKey: .unrestricted) {
            unrestricted = ticked
        } else if let askFirst = try c.decodeIfPresent(Bool.self, forKey: .askFirst) {
            unrestricted = !askFirst
        } else {
            unrestricted = false
        }
        session = try c.decodeIfPresent(String.self, forKey: .session)
        coordinator = try c.decodeIfPresent(Bool.self, forKey: .coordinator) ?? false
        mayRead = try c.decodeIfPresent([String].self, forKey: .mayRead) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(host, forKey: .host)
        try c.encode(directory, forKey: .directory)
        try c.encode(name, forKey: .name)
        try c.encode(unrestricted, forKey: .unrestricted)
        try c.encode(!unrestricted, forKey: .askFirst)
        try c.encodeIfPresent(session, forKey: .session)
        // written only when set, so a file without roles stays as an earlier build wrote it
        if coordinator { try c.encode(true, forKey: .coordinator) }
        if !mayRead.isEmpty { try c.encode(mayRead, forKey: .mayRead) }
    }
}

/// The open panes, kept in a file only the owner can read.
public enum SavedPanes {
    public static func save(_ panes: [SavedPane], to file: URL) {
        guard let data = try? JSONEncoder().encode(panes) else { return }
        let folder = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".panes-\(UUID().uuidString)")
        guard let handle = openPrivate(temporary) else { return }
        let written = (try? handle.write(contentsOf: data)) != nil
        try? handle.close()
        if !written || rename(temporary.path, file.path) != 0 { try? FileManager.default.removeItem(at: temporary) }
    }

    /// A new file only the owner can read, from the moment it exists: the mode is set as it is created.
    static func openPrivate(_ file: URL) -> FileHandle? {
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        return descriptor < 0 ? nil : FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    /// What can be trusted of the file: a pane with a bad name or host goes, a bad session id reopens fresh.
    public static func load(_ file: URL) -> [SavedPane] {
        guard let data = try? Data(contentsOf: file), let panes = try? JSONDecoder().decode([SavedPane].self, from: data) else { return [] }
        return panes.filter { PaneNames.isValid($0.name) && ($0.host.isEmpty || Hosts.isValid($0.host)) }.map { pane in
            let session = pane.session.flatMap { SessionId.isValid($0) ? $0 : nil }
            return SavedPane(kind: pane.kind, host: pane.host, directory: pane.directory, name: pane.name, unrestricted: pane.unrestricted, session: session,
                             coordinator: pane.coordinator, mayRead: pane.mayRead.filter(PaneNames.isValid))
        }
    }
}

/// What the owner can be taken to have seen.
public enum Seen {
    /// A pane counts as viewed when it has the keys with the app in front. Being on screen is not enough:
    /// in the overview every pane is, and a turn that finished there can still go unnoticed.
    public static func viewed<T: Equatable>(active: Bool, keys: T?, pane: T) -> Bool {
        active && keys == pane
    }

    /// The owner is at the window only with the app active and the window on screen. A minimized window
    /// leaves its app active, so being active alone says nothing.
    public static func inFront(active: Bool, windowOnScreen: Bool) -> Bool {
        active && windowOnScreen
    }

    /// A notification is for a pane the owner cannot see: the window is away, or another pane's tab is showing.
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

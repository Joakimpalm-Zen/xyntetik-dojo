import Darwin
import Foundation

/// D15: the panes as a file any tool on this Mac can read, `~/.dojo/live.json`, readable by the owner
/// only. Names, kinds, hosts, states, since when and labels: never a screen, a message, a session or a
/// token. `pid` says which Dojo wrote it, so a file a crash left behind reads as no Dojo. Nothing in
/// Dojo reads it back, and with no reader it is a small file nobody opens.
@MainActor
public final class LiveState {
    public let url: URL
    public let started: Date
    public var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    /// Runs `work` after `delay`; a test swaps it to fire by hand.
    public var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    /// At most one write in this many seconds, however often the panes change.
    public static let interval: TimeInterval = 1

    private var pending = false
    private var written: Data?
    private var stopped = false

    public init(url: URL, started: Date = Date()) {
        self.url = url
        self.started = started
    }

    /// The panes changed: write them out within `interval`, once.
    public func changed(_ panes: @escaping () -> [Bus.Info]) {
        guard !pending, !stopped else { return }
        pending = true
        schedule(LiveState.interval) { [weak self] in
            guard let self else { return }
            self.pending = false
            if !self.stopped { self.write(panes()) }
        }
    }

    /// The file's bytes for these panes.
    public func contents(_ panes: [Bus.Info]) -> Data {
        let format = ISO8601DateFormatter()
        let list: [[String: Any]] = panes.map { p in
            ["name": p.name, "kind": p.kind.rawValue, "host": p.host, "state": p.state.rawValue,
             "since": format.string(from: p.since), "label": p.label]
        }
        let object: [String: Any] = ["pid": Int(pid), "started": format.string(from: started), "panes": list]
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Atomic, and 0600 from the first byte: a reader never sees half a file or a file others can read.
    /// A file that cannot be written never stops anything.
    public func write(_ panes: [Bus.Info]) {
        let data = contents(panes)
        guard data != written else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".live-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
        close(fd)
        guard ok, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            return
        }
        written = data
    }

    /// At quit: no file, so no reader takes this Dojo for running.
    public func remove() {
        stopped = true
        try? FileManager.default.removeItem(at: url)
    }

    /// For a reader: the panes in a file, or nil when there is none, it does not parse, or the Dojo that
    /// wrote it is not running.
    public static func read(_ url: URL, alive: (Int32) -> Bool = LiveState.isRunning) -> [[String: Any]]? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, alive(pid) else { return nil }
        return object["panes"] as? [[String: Any]]
    }

    public static func isRunning(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

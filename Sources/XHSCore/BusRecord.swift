import CryptoKit
import Foundation

/// The record of bus traffic (D21.2): one JSON line per bus operation, in a file per day under
/// `~/.dojo/audit`, readable only by the owner. Each line carries the SHA-256 of the line before it, so
/// a removed or edited line shows. Files older than `keepDays` are deleted. The owner reads it with
/// `dojo audit`; it is not a bus route, so no pane can ask the bus for it.
@MainActor
public final class BusRecord {
    public let directory: URL
    public static let keepDays = 30
    /// The `prev` of the first line ever written.
    public static let origin = String(repeating: "0", count: 64)

    public var now: () -> Date = { Date() }
    private var lastHash: String?
    private var prunedFor: String?

    public init(directory: URL) {
        self.directory = directory
    }

    /// Appends one line: `fields` plus the time and the previous line's hash. A record that cannot be
    /// written never stops the bus.
    public func append(_ fields: [String: Any]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let day = BusRecord.day(now())
        if prunedFor != day {
            prune(today: day)
            prunedFor = day
        }
        var line = fields
        line["time"] = BusRecord.stamp(now())
        line["prev"] = lastHash ?? newestHash() ?? BusRecord.origin
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        let file = directory.appendingPathComponent(day + ".jsonl")
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data("\n".utf8))
        } catch {
            return
        }
        lastHash = BusRecord.hash(data)
    }

    /// The hash of the last line of the newest file, to carry the chain on across launches.
    private func newestHash() -> String? {
        guard let newest = BusRecord.files(in: directory).last,
              let text = try? String(contentsOf: newest, encoding: .utf8),
              let last = text.split(separator: "\n", omittingEmptySubsequences: true).last
        else { return nil }
        return BusRecord.hash(Data(last.utf8))
    }

    private func prune(today: String) {
        guard let todayDate = BusRecord.dayFormat.date(from: today),
              let cutoff = Calendar(identifier: .gregorian).date(byAdding: .day, value: -BusRecord.keepDays, to: todayDate)
        else { return }
        for file in BusRecord.files(in: directory) {
            let name = file.deletingPathExtension().lastPathComponent
            if let date = BusRecord.dayFormat.date(from: name), date < cutoff {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// The day files, oldest first. Anything else in the folder is left alone.
    public static func files(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") && dayFormat.date(from: String($0.dropLast(6))) != nil }
            .sorted().map { directory.appendingPathComponent($0) }
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func day(_ date: Date) -> String { dayFormat.string(from: date) }

    static func stamp(_ date: Date) -> String { stampFormat.string(from: date) }

    nonisolated(unsafe) static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated(unsafe) static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()
}

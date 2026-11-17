import CryptoKit
import Darwin
import Foundation

/// The record of bus traffic (D21.2): one JSON line per bus operation, in a file per day under
/// `~/.dojo/audit`, readable only by the owner. Each line carries the SHA-256 of the line before it, so
/// a line removed or edited in the middle shows. Lines cut from the end, days removed from the start and a
/// record written again with new hashes do not: the chain has no key and nothing outside the folder to
/// compare with. Files older than `keepDays` are deleted. The owner reads it with
/// `dojo audit`; it is not a bus route, so no pane can ask the bus for it.
@MainActor
public final class BusRecord {
    public let directory: URL
    public static let keepDays = 30
    /// The `prev` of the first line ever written.
    public static let origin = String(repeating: "0", count: 64)

    public var now: () -> Date = { Date() }
    private var prunedFor: String?

    public init(directory: URL) {
        self.directory = directory
    }

    /// Appends one line: `fields` plus the time and the previous line's hash. A record that cannot be
    /// written never stops the bus. Competing writers wait, then read the tail under the same lock.
    public func append(_ fields: [String: Any]) {
        do {
            try appendLocked(fields)
        } catch {
            let message = "Dojo: cannot write bus record: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
        }
    }

    private func appendLocked(_ fields: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Never unlink this file: all writers must lock the same inode, including after a crash.
        let lock = open(directory.appendingPathComponent(".writer.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        defer { flock(lock, LOCK_UN) }
        let date = now()
        let day = BusRecord.day(date)
        if prunedFor != day {
            prune(today: day)
            prunedFor = day
        }
        var line = fields
        line["time"] = BusRecord.stamp(date)
        line["prev"] = try newestHash() ?? BusRecord.origin
        let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys, .withoutEscapingSlashes])
        let file = directory.appendingPathComponent(day + ".jsonl")
        if !fm.fileExists(atPath: file.path) {
            guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data("\n".utf8))
    }

    /// Read only the tail, not the day's whole record on every append. Called with the writer lock held.
    private func newestHash() throws -> String? {
        for file in BusRecord.files(in: directory).reversed() {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var offset = try handle.seekToEnd()
            var reversedLine = Data()
            while offset > 0 {
                let count = Int(min(offset, 4096))
                offset -= UInt64(count)
                try handle.seek(toOffset: offset)
                guard let chunk = try handle.read(upToCount: count), chunk.count == count
                else { throw CocoaError(.fileReadUnknown) }
                for byte in chunk.reversed() {
                    if byte == 10 {
                        if !reversedLine.isEmpty { return BusRecord.hash(Data(reversedLine.reversed())) }
                    } else {
                        reversedLine.append(byte)
                    }
                }
            }
            if !reversedLine.isEmpty { return BusRecord.hash(Data(reversedLine.reversed())) }
        }
        return nil
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

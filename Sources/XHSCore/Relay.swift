import Darwin
import Foundation

/// A check that passes with a value or fails with the reason, in words for the caller.
public enum Checked<Value: Equatable>: Equatable {
    case success(Value)
    case failure(String)
}

/// One program the owner configured, which any pane may ask this Mac to run: `dojo relay <words...>`.
///
/// Off unless `~/.dojo/relay` exists; with no file the bus has no such route. A pane chooses the words
/// and never the program. The words go to it as an argument vector, with no shell, so they are only ever
/// data to that program, which decides what it allows. The bus sets RELAY_PANE from the caller's token,
/// so a pane cannot speak under another's name. Nothing is typed into a terminal: the result goes back to
/// the caller, and like any relayed message it is never the owner's approval of anything.
public enum Relay {
    public static let maxWords = 32
    public static let maxWordBytes = 8192
    public static let maxOutputBytes = 65536
    public static let timeout: TimeInterval = 20

    public struct Outcome: Sendable {
        public var code: Int32
        public var stdout: String
        public var stderr: String
        public var timedOut: Bool
        public var truncated: Bool
    }

    /// The configured program, nil when there is no config. The config and the program are read on every
    /// call, and neither may be something another user could change.
    public static func program(config: URL) -> Checked<String>? {
        var info = stat()
        guard stat(config.path, &info) == 0 else { return nil }
        if let why = unsafe(info, "the relay config") { return .failure(why) }
        guard let text = try? String(contentsOf: config, encoding: .utf8) else {
            return .failure("the relay config cannot be read")
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { return .failure("the relay program must be an absolute path") }
        guard stat(path, &info) == 0 else { return .failure("no relay program at \(path)") }
        if let why = unsafe(info, "the relay program") { return .failure(why) }
        guard info.st_mode & 0o111 != 0 else { return .failure("the relay program is not executable") }
        return .success(path)
    }

    private static func unsafe(_ info: stat, _ what: String) -> String? {
        if info.st_mode & S_IFMT != S_IFREG { return "\(what) is not a regular file" }
        if info.st_uid != getuid() { return "\(what) belongs to another user" }
        if info.st_mode & 0o022 != 0 { return "\(what) is writable by others" }
        return nil
    }

    /// The words of a request, or why they are refused.
    public static func words(_ value: Any?) -> Checked<[String]> {
        guard let words = value as? [String] else { return .failure("args must be a list of words") }
        if words.isEmpty { return .failure("nothing to relay") }
        if words.count > maxWords { return .failure("more than \(maxWords) words") }
        for word in words {
            if word.utf8.count > maxWordBytes { return .failure("a word is longer than \(maxWordBytes) bytes") }
            if word.utf8.contains(0) { return .failure("a word holds a NUL") }
        }
        return .success(words)
    }

    /// Runs off the caller's thread and calls `finish` once, on no particular thread.
    public static func run(program: String, words: [String], pane: String, timeout: TimeInterval = Relay.timeout,
                           finish: @escaping @Sendable (Outcome) -> Void) {
        DispatchQueue.global().async {
            let process = Process(), out = Sink(), err = Sink(), exited = DispatchSemaphore(value: 0)
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = words
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "RELAY_PANE": pane]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out.pipe
            process.standardError = err.pipe
            process.terminationHandler = { _ in exited.signal() }
            do {
                try process.run()
            } catch {
                finish(Outcome(code: 127, stdout: "", stderr: "\(error)\n", timedOut: false, truncated: false))
                return
            }
            out.drain()
            err.drain()
            var timedOut = false
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if exited.wait(timeout: .now() + 1) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    exited.wait()
                }
            }
            // A child the program left behind can hold the pipes open; it does not hold the answer.
            out.finish()
            err.finish()
            finish(Outcome(code: process.terminationStatus, stdout: out.text, stderr: err.text, timedOut: timedOut,
                           truncated: out.truncated || err.truncated))
        }
    }

    /// Reads a pipe to its end so the program never blocks on it, keeping the first bytes.
    private final class Sink: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private var dropped = false
        private let closed = DispatchSemaphore(value: 0)

        func drain() {
            let handle = pipe.fileHandleForReading
            DispatchQueue.global().async { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    let room = Relay.maxOutputBytes - data.count
                    if chunk.count > room { dropped = true }
                    if room > 0 { data.append(chunk.prefix(room)) }
                    lock.unlock()
                }
                closed.signal()
            }
        }

        func finish() { _ = closed.wait(timeout: .now() + 0.5) }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        var truncated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return dropped
        }
    }
}

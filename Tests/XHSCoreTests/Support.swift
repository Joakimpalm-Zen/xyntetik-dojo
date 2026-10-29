import Foundation
@testable import XHSCore

@MainActor
final class MockIO: PaneIO {
    var written: [[UInt8]] = []
    var screen = ""
    var bracketedPasteEnabled = false

    func write(_ bytes: [UInt8]) { written.append(bytes) }
    func screenText() -> String { screen }
    func visibleText() -> String { screen }

    /// Everything typed so far as one string.
    var typed: String { String(decoding: written.flatMap { $0 }, as: UTF8.self) }
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func body(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The argv a POSIX shell builds from a command line (without a leading "exec").
func shellArgs(_ line: String, home: String = "/home/tester") -> [String] {
    var command = line
    if command.hasPrefix("exec ") { command.removeFirst(5) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "set -- \(command); for a in \"$@\"; do printf '%s\\0' \"$a\"; done"]
    process.environment = ["HOME": home, "PATH": "/usr/bin:/bin", "SHELL": "/bin/remote-shell"]
    let pipe = Pipe()
    process.standardOutput = pipe
    try! process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
    parts.removeLast()
    return parts
}

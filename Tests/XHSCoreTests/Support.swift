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

/// How long a test gives something that must end well before the program it stopped would have: those programs
/// sleep for 30 seconds or loop for ever. It is not a measure of speed. A 5 second bound of this kind was
/// missed at 5.76 seconds on a hosted runner with three cores while other tests held the threads the tests
/// share, and a tighter one says nothing more about the code (D36).
let wellBeforeTheProgramWouldEnd: TimeInterval = 15

/// A relay program that says when it runs and then waits for the test's word, so that a test can ask the bus
/// something while the program is certainly still running, with no clock to race (D36). The tests that did
/// this by sleeping a tenth of a second beside a program that slept half a second failed on a slow runner.
/// The program gives up after 10 seconds and says so, so a bus that did wait for it still answers, and the
/// test sees that it waited.
struct RelayGate {
    let started = FileManager.default.temporaryDirectory.appendingPathComponent("relay-started-\(UUID().uuidString)")
    let release = FileManager.default.temporaryDirectory.appendingPathComponent("relay-go-\(UUID().uuidString)")
    let abandoned = FileManager.default.temporaryDirectory.appendingPathComponent("relay-gave-up-\(UUID().uuidString)")

    /// Prints the pane and its first word once the gate is open, as the relay tests' own programs do.
    var script: String {
        """
        #!/bin/sh
        : > "\(started.path)"
        n=0
        while [ ! -e "\(release.path)" ] && [ $n -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
        [ -e "\(release.path)" ] || : > "\(abandoned.path)"
        echo "$RELAY_PANE $1"

        """
    }

    /// Returns once the program runs; false if it has not started in 20 seconds.
    func running() async -> Bool {
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: started.path) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func open() { FileManager.default.createFile(atPath: release.path, contents: nil) }

    /// The program ran out of patience before the gate opened: whatever the test asked meanwhile was held up.
    var gaveUp: Bool { FileManager.default.fileExists(atPath: abandoned.path) }

    func remove() {
        for file in [started, release, abandoned] { try? FileManager.default.removeItem(at: file) }
    }
}

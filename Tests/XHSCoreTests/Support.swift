import Foundation
@testable import XHSCore

@MainActor
final class MockIO: PaneIO {
    var written: [[UInt8]] = []
    var bracketedPasteEnabled = false
    var columns = 0
    /// The used cells of the screen's rows, for a test of what `read` does with them; nil as for a pane
    /// that cannot tell.
    var cells: [Int]?
    func usedCells(last: Int) -> [Int]? { cells }
    /// The line the terminal's cursor is on, for a test of that evidence; nil as for a pane that cannot say.
    var cursorLine: Int?
    /// Whether the terminal shows its alternate buffer; nil as for a pane that cannot say.
    var alternate: Bool?
    /// The live screen's lines where they differ from the pane's text: a real pane's text can hold what a
    /// wider pane once had beyond its right edge, which the live screen leaves out (D37).
    var live: [String]?
    let kind: HarnessKind
    /// What the test set the screen to, if it did.
    private var set: String?
    /// What was typed since the last Enter.
    private var draft = ""

    /// The kind of harness whose screen this pane shows when the test sets none.
    init(kind: HarnessKind = .claude) { self.kind = kind }

    /// What the pane shows. The bus types only into a composer it can see, and presses Enter only once the
    /// composer holds what it pasted (D35.1), so a pane in a test shows what a harness of its kind would: its
    /// composer, holding what was typed since the last Enter. A test that sets the screen has it as set.
    var screen: String {
        get { set ?? MockIO.screen(kind, holding: draft) }
        set { set = newValue }
    }

    func write(_ bytes: [UInt8]) {
        written.append(bytes)
        if bytes == Delivery.enter { draft = "" } else {
            draft += String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}[200~", with: "")
                .replacingOccurrences(of: "\u{1b}[201~", with: "")
        }
    }

    func screenText() -> String { screen }
    func visibleText() -> String { screen }
    func liveScreen() -> PaneScreen { PaneScreen(lines: live ?? screen.components(separatedBy: "\n"), cursorLine: cursorLine, alternate: alternate) }

    /// Everything typed so far as one string.
    var typed: String { String(decoding: written.flatMap { $0 }, as: UTF8.self) }

    /// A harness's screen with an empty composer: what a pane shows once the text in it was sent.
    static func emptied(_ kind: HarnessKind) -> String {
        switch kind {
        case .claude: return "──────────────────────────────\n❯\u{a0}\n──────────────────────────────\n  status\n"
        case .codex: return "\n› Ask Codex to do anything\n\n  status · line\n"
        case .pi, .runner, .shell: return ""
        }
    }

    /// A harness's screen with `text` in its composer, as the two harnesses draw it: Claude Code between two
    /// ruled lines with a stand-in for a paste of several lines, Codex after an empty row with later rows set
    /// in. With nothing typed the composer holds a word, so that it is a composer and not an empty one, which
    /// would end a draft hold.
    static func screen(_ kind: HarnessKind, holding text: String) -> String {
        let rows = (text.isEmpty ? "word" : text).components(separatedBy: "\n")
        switch kind {
        case .claude:
            let shown = rows.count > 1 ? "[Pasted text #1 +\(rows.count - 1) lines]" : rows[0]
            return "──────────────────────────────\n❯ \(shown)\n──────────────────────────────\n  status\n"
        case .codex:
            return "\n› " + rows.joined(separator: "\n  ") + "\n\n  status · line\n"
        case .pi, .runner, .shell:
            return ""
        }
    }
}

func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func body(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The argv a POSIX shell builds from a command line (without a leading "exec").
/// The words of the harness command in the line a host's login shell reads: what follows the last `exec`,
/// after the folder change and, for a pane that reports hooks, its check of the way to the bus (D35.2).
func harnessArgs(_ inner: String, home: String = "/home/tester") -> [String] {
    shellArgs(inner.components(separatedBy: " && exec ").last ?? inner, home: home)
}

/// The words of that check, nil when the line has none.
func reachArgs(_ inner: String, home: String = "/home/tester") -> [String]? {
    // what stands before the harness: the folder change, if any, and the check
    let head = inner.components(separatedBy: " && exec ").dropLast().joined(separator: " && exec ")
    if head.hasPrefix("env ") { return shellArgs(head, home: home) }
    return head.range(of: " && env ").map { shellArgs("env " + String(head[$0.upperBound...]), home: home) }
}

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

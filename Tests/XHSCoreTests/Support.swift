import Foundation
@testable import XHSCore

@MainActor
final class MockIO: PaneIO {
    var written: [[UInt8]] = []
    var bracketedPasteEnabled = false
    /// The line the terminal's cursor is on, for a test of that evidence; nil as for a pane that cannot say.
    var cursorLine: Int?
    /// Whether the terminal shows its alternate buffer; nil as for a pane that cannot say.
    var alternate: Bool?
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
    func liveScreen() -> PaneScreen { PaneScreen(lines: screen.components(separatedBy: "\n"), cursorLine: cursorLine, alternate: alternate) }

    /// Everything typed so far as one string.
    var typed: String { String(decoding: written.flatMap { $0 }, as: UTF8.self) }

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

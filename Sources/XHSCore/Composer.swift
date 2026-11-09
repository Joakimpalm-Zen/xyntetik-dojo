import Foundation

/// Reads a harness's composer off its screen, to end a draft hold that no hook will end. A turn the harness
/// refuses before its submit hook (a usage limit, an auth error, a crash) takes the owner's text out of the
/// composer and reports nothing, so the bus would hold its queue for good (D18).
///
/// It answers only from what it knows for sure: the composer row of a harness it has a rule for, empty or
/// showing that harness's own placeholder, with nothing in the row under it. Anything else, a placeholder a
/// later version brings, a draft over two rows, a screen scrolled away, a harness with no rule, is not shown
/// empty, and the hold stays. A miss costs only the old behaviour; a false yes would type into the owner's text.
public enum Composer {
    struct Rule {
        /// What the composer row starts with.
        var marks: [String]
        /// What the harness shows in an empty composer. Taken from the harness itself, not guessed.
        var placeholders: Set<String>
    }

    /// Codex 0.166.0: the composer is `› ` and its placeholders are in the binary. Claude Code: `❯` and a
    /// no-break space, and nothing after it.
    static func rule(for kind: HarnessKind) -> Rule? {
        switch kind {
        case .codex: return Rule(marks: ["›"], placeholders: ["Ask Codex to do anything", "Ask a follow-up question", "Waiting for startup"])
        case .claude: return Rule(marks: ["❯", ">"], placeholders: [])
        case .pi, .runner, .shell: return nil
        }
    }

    /// The composer sits at the foot of the screen, under the transcript.
    static let footRows = 12

    public static func shownEmpty(kind: HarnessKind, screen: String) -> Bool {
        guard let rule = rule(for: kind) else { return false }
        let blank = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{a0}"))
        var rows = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: blank.union(.newlines)) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        let foot = Array(rows.suffix(footRows))
        // The lowest one: past prompts in the transcript above can start with the same mark.
        guard let at = foot.lastIndex(where: { row in rule.marks.contains { row.hasPrefix($0) } }),
              let mark = rule.marks.first(where: { foot[at].hasPrefix($0) }) else { return false }
        let rest = String(foot[at].dropFirst(mark.count)).trimmingCharacters(in: blank)
        guard rest.isEmpty || rule.placeholders.contains(rest) else { return false }
        // A draft that goes on in the next row is not empty, however its first row looks.
        guard at + 1 < foot.count else { return true }
        let next = foot[at + 1]
        return next.isEmpty || next.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) || blank.contains($0) }
    }
}

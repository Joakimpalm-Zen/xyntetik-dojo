import Foundation

/// Reads a harness's composer off its screen, to end a draft hold that no hook will end. A turn the harness
/// refuses before its submit hook (a usage limit, an auth error, a crash) takes the owner's text out of the
/// composer and reports nothing, so the bus would hold its queue for good (D18).
///
/// It answers only from what it knows for sure: the composer row of a harness it has a rule for, empty or
/// showing that harness's own placeholder (alone, or padded out to a hint the harness drew at the right edge),
/// with nothing in the row under it. Anything else, a placeholder a
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

    /// How far up from the foot `shown` looks: a message the bus pasted can fill many rows of the composer.
    static let shownFootRows = 40
    /// How many rows a Codex composer has under it before the bus has typed anything: its status and hint lines,
    /// with room to spare. More than that under the lowest mark is a transcript, not a composer.
    static let codexRowsUnder = 6

    /// Whether the screen shows the harness's composer, the place typed text goes (D35.1). The bus types a
    /// message, and presses its Enter, only into a composer it can see: a permission prompt or any other
    /// dialog takes the composer off the screen, and until now the bus knew of one only from a hook, which can
    /// be lost. Nil for a harness with no rule, which is typed into as before.
    ///
    /// Claude Code draws its composer under a ruled line. Codex draws it after an empty row, as the lowest row
    /// with its mark, with only its status lines below. A dialog's highlighted choice carries the same mark as
    /// the composer, in both harnesses, and can stand under a rule or after an empty row too, so a row that
    /// reads as a numbered choice ("1. Yes") is never a composer.
    ///
    /// `afterPaste`: the bus's own text is in the composer and may fill rows under the mark, so the rows under
    /// a Codex composer are not counted.
    public static func shown(kind: HarnessKind, screen: String, afterPaste: Bool = false) -> Bool? {
        guard let rule = rule(for: kind) else { return nil }
        let blank = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{a0}"))
        var rows = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: blank.union(.newlines)) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        let foot = Array(rows.suffix(shownFootRows))
        func rest(_ at: Int) -> String? {
            guard let mark = rule.marks.first(where: { foot[at].hasPrefix($0) }) else { return nil }
            return String(foot[at].dropFirst(mark.count)).trimmingCharacters(in: blank)
        }
        switch kind {
        case .claude:
            return foot.indices.contains { at in
                guard at > 0, let rest = rest(at) else { return false }
                return isRuledLine(foot[at - 1]) && !isNumberedChoice(rest)
            }
        case .codex:
            guard let at = foot.indices.last(where: { rest($0) != nil }), let rest = rest(at), !isNumberedChoice(rest) else { return false }
            guard at == 0 || foot[at - 1].isEmpty else { return false }
            return afterPaste || foot[(at + 1)...].filter({ !$0.isEmpty }).count <= codexRowsUnder
        case .pi, .runner, .shell:
            return nil
        }
    }

    /// A row that starts with a run of box-drawing characters, as the line over Claude Code's composer does;
    /// the line may carry the session's name near its end.
    static func isRuledLine(_ row: String) -> Bool {
        let head = row.unicodeScalars.prefix(8)
        return head.count == 8 && head.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// "1. Yes", "12. Chat about this": how both harnesses draw the choices of a dialog.
    static func isNumberedChoice(_ text: String) -> Bool {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        return !digits.isEmpty && digits.count <= 2 && text.dropFirst(digits.count).hasPrefix(". ")
    }

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
        // Codex draws a hint at the right edge of the same row when a usage limit is near ("4 on 17 Nov ·
        // /status"). A placeholder is only drawn in an empty composer, so one followed by the harness's own
        // padding is still empty; a single space and more words is the owner's text.
        let padded = rule.placeholders.contains { rest.hasPrefix($0 + "  ") }
        guard rest.isEmpty || rule.placeholders.contains(rest) || padded else { return false }
        // A draft that goes on in the next row is not empty, however its first row looks.
        guard at + 1 < foot.count else { return true }
        let next = foot[at + 1]
        return next.isEmpty || next.unicodeScalars.allSatisfy { (0x2500...0x257F).contains($0.value) || blank.contains($0) }
    }
}

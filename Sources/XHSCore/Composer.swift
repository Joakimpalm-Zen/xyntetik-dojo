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
    /// How many rows either harness has under its composer: its status lines and a hint row, with room to
    /// spare. More than that under the lowest mark is a transcript or a dialog, not a footer.
    static let footerRows = 4
    /// What a dialog says about its keys, in either harness, and no footer does: read off Codex's own menu
    /// ("enter select · esc back") and its approval, and off Claude Code's dialogs. Lowercase.
    static let dialogKeyHints = ["enter select", "enter to select", "enter to confirm", "press enter", "esc back",
                                 "esc to cancel", "esc to go back", "tab to amend", "to navigate"]

    /// Whether the screen shows the harness's composer as the place typed text goes right now (D35.1). The
    /// bus types a message, and presses its Enter, only into a composer it can see: a permission prompt or
    /// any other dialog takes the composer off the screen, and the bus knew of one only from a hook, which
    /// can be lost. Nil for a harness with no rule, which is typed into as before.
    ///
    /// A wrong "no" costs a held message, which the pane's header shows and the owner can act on; a wrong
    /// "yes" types into a dialog. So the rule is about what stands at the foot of the screen, and it says yes
    /// only to a composer that is the last thing there:
    ///
    /// - The lowest row that starts, in the first column, with the composer's mark is the composer or nothing
    ///   is. A dialog's highlighted choice carries the same mark, so a row that reads as a numbered choice
    ///   ("1. Yes", or "1." where a narrow pane cut it) is not a composer. Rows set in, such as the later
    ///   rows of a long message, are never taken for a mark.
    /// - Claude Code draws its composer between two ruled lines; Codex draws it after an empty row.
    /// - Before the bus has typed anything, the composer is one row.
    /// - After it has pasted (`afterPaste`), the composer must hold what it pasted: `pasted` itself, row by
    ///   row, or the harness's stand-in for a long paste ("[Pasted text #3 +4 lines]", "[Pasted Content 1200
    ///   chars]"). A composer that holds anything else, or nothing yet, is not pressed Enter on: the text
    ///   has not arrived there, or something else has.
    /// - Under the composer stand at most `footerRows` rows, every one set in as both harnesses set their
    ///   status and hint rows, none a numbered choice, none with a dialog's key hints. The rows themselves
    ///   cannot be known word for word: the status line is the owner's own, and the hint row changes
    ///   ("paste again to expand" after a paste).
    ///
    /// - Where the terminal says which line its cursor is on (`cursorLine`), the cursor must be on the
    ///   composer: a dialog moves it. Whether a harness keeps its cursor there has to be seen in a real pane
    ///   first, so the bus passes it only for the harnesses it is told to (`Bus.cursorEvidence`).
    ///
    /// Without `pasted` an `afterPaste` reading goes by the shape alone. `screen` is read row by row;
    /// `lines` are the terminal's own lines, where rows it wrapped are already joined.
    public static func shown(kind: HarnessKind, screen: String, afterPaste: Bool = false, pasted: String? = nil) -> Bool? {
        shown(kind: kind, lines: screen.components(separatedBy: "\n"), cursorLine: nil, afterPaste: afterPaste, pasted: pasted)
    }

    public static func shown(kind: HarnessKind, lines: [String], cursorLine: Int?, afterPaste: Bool = false,
                             pasted: String? = nil) -> Bool? {
        guard let rule = rule(for: kind) else { return nil }
        let blank = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\u{a0}")).union(.newlines)
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: blank).isEmpty { lines.removeLast() }
        let dropped = max(lines.count - shownFootRows, 0)
        let foot: [(text: String, setIn: Bool)] = lines.suffix(shownFootRows).map { line in
            (line.trimmingCharacters(in: blank), line.unicodeScalars.first.map(blank.contains) ?? false)
        }
        /// What follows the mark on a row that starts with it in the first column.
        func afterMark(_ at: Int) -> String? {
            guard !foot[at].setIn, let mark = rule.marks.first(where: { foot[at].text.hasPrefix($0) }) else { return nil }
            return String(foot[at].text.dropFirst(mark.count)).trimmingCharacters(in: blank)
        }
        guard let at = foot.indices.last(where: { afterMark($0) != nil }), let first = afterMark(at),
              !isNumberedChoice(first) else { return false }
        /// The composer's rows from `at` to `end`, without the mark.
        func rows(to end: Int) -> [String] { [first] + foot[(at + 1)..<max(end, at + 1)].map(\.text) }
        let end: Int        // the first row under the composer: its footer starts here
        var block: Int      // the first row that is not the composer's own text
        switch kind {
        case .claude:
            guard at > 0, isRuledLine(foot[at - 1].text),
                  let closing = foot.indices.first(where: { $0 > at && isRuledLine(foot[$0].text) }) else { return false }
            if afterPaste {
                if let pasted, !holds(pasted, rows: rows(to: closing), standIn: "[Pasted text #") { return false }
            } else if closing != at + 1 {
                return false
            }
            block = closing
            end = closing + 1
        case .codex:
            guard at == 0 || foot[at - 1].text.isEmpty else { return false }
            if afterPaste, let pasted {
                // the pasted text may have empty rows of its own: it ends where it has all been seen
                guard let last = (at..<foot.count).first(where: { holds(pasted, rows: rows(to: $0 + 1), standIn: "[Pasted Content ") })
                else { return false }
                end = last + 1
            } else if afterPaste {
                end = foot.indices.first(where: { $0 > at && (foot[$0].text.isEmpty || !foot[$0].setIn) }) ?? foot.count
            } else {
                guard at + 1 == foot.count || foot[at + 1].text.isEmpty else { return false }
                end = at + 1
            }
            block = end
        case .pi, .runner, .shell:
            return nil
        }
        block = max(block, at + 1)
        if let cursorLine, !(at..<block).contains(cursorLine - dropped) { return false }
        let under = foot[min(end, foot.count)...].filter { !$0.text.isEmpty }
        return under.count <= footerRows && under.allSatisfy { row in
            // set in as a footer is, not a choice, not the frame of a dialog, and without a dialog's key hints
            row.setIn && !isNumberedChoice(row.text) && !startsWithBoxDrawing(row.text)
                && !dialogKeyHints.contains { row.text.lowercased().contains($0) }
        }
    }

    /// A row that begins with a box-drawing character: a ruled line, or the edge of a frame a dialog draws.
    /// Only the beginning counts. A status row can end in a few such characters that a wider line left
    /// behind at the right edge; a pane showed that on 2026-11-15.
    static func startsWithBoxDrawing(_ row: String) -> Bool {
        row.unicodeScalars.first.map { (0x2500...0x257F).contains($0.value) } ?? false
    }

    /// Whether the composer's rows are what the bus pasted, or the harness's stand-in for it. Row breaks and
    /// spaces are not compared: the harness wraps a long line where it likes.
    static func holds(_ pasted: String, rows: [String], standIn: String) -> Bool {
        if rows.count == 1, rows[0].hasPrefix(standIn), rows[0].hasSuffix("]") { return true }
        func bare(_ text: String) -> [Unicode.Scalar] { text.unicodeScalars.filter { !$0.properties.isWhitespace } }
        return bare(rows.joined()) == bare(pasted)
    }

    /// A row that starts with a run of box-drawing characters, as the lines around Claude Code's composer
    /// do; the line may carry the session's name near its end.
    static func isRuledLine(_ row: String) -> Bool {
        let head = row.unicodeScalars.prefix(8)
        return head.count == 8 && head.allSatisfy { (0x2500...0x257F).contains($0.value) }
    }

    /// "1. Yes", "12. Chat about this", and "1." where a narrow pane cut the row after the number: how both
    /// harnesses draw the choices of a dialog.
    static func isNumberedChoice(_ text: String) -> Bool {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let rest = text.dropFirst(digits.count)
        return !digits.isEmpty && digits.count <= 2 && (rest == "." || rest.hasPrefix(". "))
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

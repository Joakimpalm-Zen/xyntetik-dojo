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
    /// What each harness writes in its composer in place of a long paste, up to the part that changes.
    static func standIn(for kind: HarnessKind) -> String { kind == .codex ? "[Pasted Content " : "[Pasted text #" }
    /// A hint row a harness shows under its composer once text has been pasted, which was not there before:
    /// read off panes of both on 2026-11-15. Codex shows its own only while it works; idle, its hint row just
    /// loses a part.
    static func hintsAfterAPaste(for kind: HarnessKind) -> [String] {
        switch kind {
        case .claude: return ["paste again to expand"]
        case .codex: return ["tab to queue message"]
        case .pi, .runner, .shell: return []
        }
    }

    /// What a harness writes in a free composer that holds no typed text, where that is not an empty one by
    /// `shownEmpty`: Claude Code's row once a message is queued behind the turn it is working on, read off a
    /// pane on 2026-11-15. It is known only where the bus asks what the owner's Enter did with the text it
    /// pasted; a draft hold ends on an empty composer as before.
    static func rowsOfAComposerTheTextLeft(for kind: HarnessKind) -> [String] {
        kind == .claude ? ["Press up to edit queued messages"] : []
    }

    /// What the bus saw of a composer when it typed into it: what the composer's row said after its mark, and
    /// the rows under it. The Enter is pressed against this.
    public struct Look: Equatable, Sendable {
        public var composer: String
        public var under: [String]

        public init(composer: String, under: [String]) {
            self.composer = composer
            self.under = under
        }
    }

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
    /// - Before the bus has typed anything, the composer is one row, and it does not already hold a paste.
    /// - After it has pasted (`afterPaste`), the composer must hold what it pasted: `pasted` itself, row by
    ///   row, or the harness's stand-in for a long paste ("[Pasted text #3 +4 lines]", "[Pasted Content 1200
    ///   chars]"). A stand-in that was in the composer already says nothing about this paste: a composer
    ///   that shows one is not typed into, and at the Enter the composer's row must not be what it was at the
    ///   look before the paste (`before`). A composer that holds anything else, or nothing yet, is not
    ///   pressed Enter on: the text has not arrived there, or something else has.
    /// - Under the composer stand at most `footerRows` rows, every one set in as both harnesses set their
    ///   status and hint rows, none a numbered choice, none the frame of a dialog, none with a dialog's key
    ///   hint as whole words outside a path. The rows themselves cannot be known word for word: the status line is the owner's own, and
    ///   the hint row changes.
    /// - After the paste, no row under the composer may be new since `before`: a dialog can open under a
    ///   composer that stays on the screen. A row is not new when it is one that was there, each run of
    ///   digits read as one sign (a status line counts on), or that row with whole parts taken away (a hint
    ///   row loses a part when text arrives), or one of the harness's own hint rows after a paste, word for
    ///   word. A row that has gained anything is new. The rows are matched one for one, in their order, so
    ///   a row that was added is new whatever it says.
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
                             pasted: String? = nil, before: Look? = nil) -> Bool? {
        guard rule(for: kind) != nil else { return nil }
        return read(kind: kind, lines: lines, cursorLine: cursorLine, afterPaste: afterPaste, pasted: pasted, before: before) != nil
    }

    /// The composer as it stands before the bus types into it; nil when it may not type there.
    public static func look(kind: HarnessKind, lines: [String], cursorLine: Int?) -> Look? {
        read(kind: kind, lines: lines, cursorLine: cursorLine, afterPaste: false, pasted: nil, before: nil)
    }

    /// The composer as it stands holding what the bus pasted, with the rows under it as they are now; nil
    /// when it does not hold that, or the rows under it show a dialog. The rows are not held against the
    /// look before the paste here: `footerUnchanged` does that.
    public static func holding(kind: HarnessKind, lines: [String], cursorLine: Int?, pasted: String, before: Look?) -> Look? {
        read(kind: kind, lines: lines, cursorLine: cursorLine, afterPaste: true, pasted: pasted, before: before, compareFooter: false)
    }

    /// Whether the rows under the composer are the ones from before the paste, one for one: each row now is
    /// a different row from before (`wasThere`), in their order, so there cannot be more of them than
    /// before. One of the harness's own hint rows after a paste stands in the place of one row from before.
    /// A row that was added holds the Enter even when it reads like part of an old one.
    public static func footerUnchanged(_ now: [String], since before: [String], kind: HarnessKind) -> Bool {
        let hints = hintsAfterAPaste(for: kind)
        var next = 0
        for row in now {
            if hints.contains(row) {
                guard next < before.count else { return false }
                next += 1
            } else if let found = before[next...].firstIndex(where: { wasThere(row, $0) }) {
                next = found + 1
            } else {
                return false
            }
        }
        return true
    }

    /// How many characters in a row a text must have in common with what the bus pasted to be taken for
    /// that paste, edited.
    static let editedRun = 8

    /// Whether `text` holds a run of `editedRun` characters or more that `pasted` also holds, blanks apart:
    /// then it is the paste with something changed, added or taken away, not something the harness wrote.
    /// A suggestion of the harness's that happens to repeat that much of a message reads as an edit too.
    static func sharesARun(with pasted: String, _ text: String) -> Bool {
        let a = Array(pasted.unicodeScalars.filter { !$0.properties.isWhitespace })
        let b = Array(text.unicodeScalars.filter { !$0.properties.isWhitespace })
        guard a.count >= editedRun, b.count >= editedRun else { return false }
        var runs = Set<[Unicode.Scalar]>()
        for at in 0...(a.count - editedRun) { runs.insert(Array(a[at..<(at + editedRun)])) }
        return (0...(b.count - editedRun)).contains { runs.contains(Array(b[$0..<($0 + editedRun)])) }
    }

    /// Whether two texts are the same but for their blanks and line breaks, which a harness lays out as it
    /// likes.
    public static func sameText(_ a: String, _ b: String) -> Bool {
        func bare(_ text: String) -> [Unicode.Scalar] { text.unicodeScalars.filter { !$0.properties.isWhitespace } }
        return bare(a) == bare(b)
    }

    private static func read(kind: HarnessKind, lines: [String], cursorLine: Int?, afterPaste: Bool, pasted: String?,
                             before: Look?, compareFooter: Bool = true) -> Look? {
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
              !isNumberedChoice(first) else { return nil }
        let standIn = Composer.standIn(for: kind)
        /// The composer's rows from `at` to `end`, without the mark.
        func rows(to end: Int) -> [String] { [first] + foot[(at + 1)..<max(end, at + 1)].map(\.text) }
        func arrived(_ rows: [String]) -> Bool { pasted.map { Composer.arrived($0, rows: rows, standIn: standIn, before: before) } ?? true }
        let end: Int        // the first row under the composer: its footer starts here
        var block: Int      // the first row that is not the composer's own text
        switch kind {
        case .claude:
            guard at > 0, isRuledLine(foot[at - 1].text),
                  let closing = foot.indices.first(where: { $0 > at && isRuledLine(foot[$0].text) }) else { return nil }
            if afterPaste {
                guard arrived(rows(to: closing)) else { return nil }
            } else if closing != at + 1 || isStandIn(first, standIn) {
                return nil
            }
            block = closing
            end = closing + 1
        case .codex:
            guard at == 0 || foot[at - 1].text.isEmpty else { return nil }
            if afterPaste, pasted != nil {
                // the pasted text may have empty rows of its own: it ends where it has all been seen
                guard let last = (at..<foot.count).first(where: { arrived(rows(to: $0 + 1)) }) else { return nil }
                end = last + 1
            } else if afterPaste {
                end = foot.indices.first(where: { $0 > at && (foot[$0].text.isEmpty || !foot[$0].setIn) }) ?? foot.count
            } else {
                guard at + 1 == foot.count || foot[at + 1].text.isEmpty, !isStandIn(first, standIn) else { return nil }
                end = at + 1
            }
            block = end
        case .pi, .runner, .shell:
            return nil
        }
        block = max(block, at + 1)
        if let cursorLine, !(at..<block).contains(cursorLine - dropped) { return nil }
        let under = foot[min(end, foot.count)...].filter { !$0.text.isEmpty }
        guard under.count <= footerRows, under.allSatisfy({ row in
            // set in as a footer is, not a choice, not the frame of a dialog, and without a dialog's key hints
            row.setIn && !isNumberedChoice(row.text) && !startsWithBoxDrawing(row.text) && !hasKeyHint(row.text)
        }) else { return nil }
        if afterPaste, compareFooter, let before {
            guard footerUnchanged(under.map(\.text), since: before.under, kind: kind) else { return nil }
        }
        return Look(composer: first, under: under.map(\.text))
    }

    /// Whether the composer's rows are what the bus pasted, or the harness's stand-in for it. Row breaks and
    /// spaces are not compared: the harness wraps a long line where it likes.
    static func holds(_ pasted: String, rows: [String], standIn: String) -> Bool {
        arrived(pasted, rows: rows, standIn: standIn, before: nil)
    }

    /// `holds`, against the look before the paste: a stand-in that was in the composer already says nothing
    /// about this paste, so it counts only when the composer's row has changed.
    static func arrived(_ pasted: String, rows: [String], standIn: String, before: Look?) -> Bool {
        if rows.count == 1, isStandIn(rows[0], standIn) { return rows[0] != before?.composer }
        return sameText(rows.joined(), pasted)
    }

    static func isStandIn(_ row: String, _ standIn: String) -> Bool { row.hasPrefix(standIn) && row.hasSuffix("]") }

    /// The parts of a footer row, as both harnesses lay one out: side by side, parted by a middle dot between
    /// spaces or by a gap of two or more spaces (Codex sets a left part and a right part of its hint row that
    /// far apart). Each run of digits is read as one sign whatever its length, so a counter that goes from 9
    /// to 10 is the same part.
    static func parts(_ row: String) -> [String] {
        var out: [String] = []
        for piece in row.components(separatedBy: " · ").flatMap({ $0.components(separatedBy: "  ") }) {
            var part = "", inDigits = false
            for character in piece.trimmingCharacters(in: .whitespaces) {
                let digit = character.isASCII && character.isNumber
                if !digit { part.append(character) } else if !inDigits { part.append("#") }
                inDigits = digit
            }
            if !part.isEmpty { out.append(part) }
        }
        return out
    }

    /// Whether a row under the composer was there before the paste. It was when, part for part, it is a row
    /// that was there, or that row with whole parts taken away, the rest in their order. A row that has
    /// gained a part, or any text inside one, is new: a dialog's question put after an old hint is not the
    /// old hint.
    static func wasThere(_ row: String, _ before: String) -> Bool {
        let now = parts(row), then = parts(before)
        guard !now.isEmpty else { return false }
        var matched = 0
        for part in then where matched < now.count && part == now[matched] { matched += 1 }
        return matched == now.count
    }

    /// Whether a row carries a dialog's key hint. A hint is whole words: it begins where a word begins (the
    /// start of a part of the row, after a space, or after an opening bracket) and ends where a word ends.
    /// A path is the owner's status and never a hint, whatever the folder is called: it begins at a word
    /// that starts with a tilde or a slash and runs to the end of its part. A slash inside a word ("↑/↓",
    /// "Esc/Ctrl+C", "(y/n)") begins no path.
    static func hasKeyHint(_ row: String) -> Bool {
        let parts = row.lowercased().components(separatedBy: " · ").flatMap { $0.components(separatedBy: "  ") }
        return parts.contains { piece in
            var part = Array(piece.trimmingCharacters(in: .whitespaces))
            if let path = part.indices.first(where: { "~/".contains(part[$0]) && ($0 == 0 || part[$0 - 1] == " ") }) {
                part = Array(part[..<path])
            }
            return dialogKeyHints.contains { hint in
                let words = Array(hint)
                guard part.count >= words.count else { return false }
                return (0...(part.count - words.count)).contains { at in
                    (at == 0 || " ([{".contains(part[at - 1])) && Array(part[at..<(at + words.count)]) == words
                        && !(at + words.count < part.count && part[at + words.count].isLetter)
                }
            }
        }
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

    /// A row that begins with a box-drawing character: a ruled line, or the edge of a frame a dialog draws.
    /// Only the beginning counts. A status row can end in a few such characters that a wider line left
    /// behind at the right edge; a pane showed that on 2026-11-15.
    static func startsWithBoxDrawing(_ row: String) -> Bool {
        row.unicodeScalars.first.map { (0x2500...0x257F).contains($0.value) } ?? false
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

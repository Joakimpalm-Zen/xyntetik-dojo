import Foundation

/// What `read` hands another pane, with secrets taken out (D21.2, step 2). Always on: the owner chose no
/// switch. The owner's own view of a pane is never changed; only the text that leaves the bus is.
///
/// Three passes. Every live bus token is replaced exactly, even when the terminal wrapped it across two rows:
/// the bus knows them all, so that one is a guarantee. Then the keys with a fixed shape that the screen
/// wrapped at the pane's width (D35.4), and then the known secret shapes in `rules`, the short list below, after
/// the rule sets of gitleaks and detect-secrets. A pattern list misses things, so this is a backstop; who may
/// read at all is the primary control (step 3, roles).
///
/// Lines keep their place: a secret becomes a marker on its own row, and a private key block keeps one empty
/// row for each row it had.
public enum Redact {
    public struct Outcome: Equatable {
        public let text: String
        /// How many secrets were taken out.
        public let count: Int
    }

    public static let tokenMarker = "[dojo token]"

    /// `width`: the columns of the pane the text was read off, for keys the screen wrapped; 0 for text that
    /// was never on a screen. `cells`: for each row of the text, how many of the terminal's cells it uses,
    /// which the pane knows and the text does not say (a wide character fills two, a flag is two characters
    /// in one cell); nil where no pane gave them.
    public static func apply(_ text: String, tokens: [String], width: Int = 0, cells: [Int]? = nil) -> Outcome {
        var count = 0
        // Which rows reach the pane's width is read off the rows as they came, before any pass replaces
        // anything: a bus token taken out of a row makes it shorter than the screen had it.
        let reaches = rowsThatReach(width, text, cells: cells)
        var out = tokensOut(text, tokens, &count)
        out = wrappedOut(out, reaches: reaches, &count)
        for rule in rules { out = rule.apply(out, &count) }
        return Outcome(text: out, count: count)
    }

    // MARK: the bus's own tokens

    /// Replaces each token wherever it appears, also split by a row break; the break stays where it was.
    static func tokensOut(_ text: String, _ tokens: [String], _ count: inout Int) -> String {
        let live = Set(tokens.filter { $0.count >= 16 })
        guard !live.isEmpty else { return text }
        let chars = Array(text)
        // the characters other than row breaks, and where each one is in `chars`
        var flat: [Character] = []
        var at: [Int] = []
        for (i, c) in chars.enumerated() where c != "\n" {
            flat.append(c)
            at.append(i)
        }
        var hits: [(start: Int, end: Int)] = []
        for token in live {
            let t = Array(token)
            var i = 0
            while i + t.count <= flat.count {
                if flat[i] == t[0], flat[i..<i + t.count].elementsEqual(t) {
                    hits.append((i, i + t.count))
                    i += t.count
                } else {
                    i += 1
                }
            }
        }
        guard !hits.isEmpty else { return text }
        hits.sort { $0.start < $1.start }
        var drop = [Bool](repeating: false, count: chars.count)
        var markAt = Set<Int>()
        var last = -1
        for hit in hits where hit.start >= last {
            for k in hit.start..<hit.end { drop[at[k]] = true }
            markAt.insert(at[hit.start])
            last = hit.end
            count += 1
        }
        var out = ""
        for (i, c) in chars.enumerated() {
            if markAt.contains(i) { out += tokenMarker }
            if !drop[i] { out.append(c) }
        }
        return out
    }

    // MARK: keys the terminal wrapped

    /// For each row of the text, whether it reaches the pane's width. That is not worked out from the text
    /// alone: how many columns a character takes depends on the terminal and on the characters beside it.
    /// A row counts by its characters, which is right for text of one column each, and where the pane gave
    /// how many of the row's cells it uses within its width (`cells`), by that count where it is the larger,
    /// as it is for a row of wide characters. The larger of the two, because they are not the same row
    /// everywhere: after a narrowing the terminal keeps a row's cells past the new right edge, the text has
    /// them, and the terminal's count stops at the edge (SwiftTerm 1.99.1 gives the cells of a row only up to
    /// the width, and the stored row is not public). The cost: where that part past the edge holds wide
    /// characters, it counts by its characters. Empty when no width is known.
    static func rowsThatReach(_ width: Int, _ text: String, cells: [Int]?) -> [Bool] {
        let full = width - wrapMargin
        guard full > 8 else { return [] }
        let rows = text.components(separatedBy: "\n")
        if let cells, cells.count == rows.count { return zip(cells, rows).map { max($0, $1.count) >= full } }
        return rows.map { $0.count >= full }
    }

    /// How far short of the pane's width a row may end and still be one the screen wrapped: a harness wraps
    /// its own text a little inside the edge.
    static let wrapMargin = 4

    /// A key with a fixed shape that runs past the right edge goes on in the next row, and no rule that reads
    /// row by row sees it whole (D35.4). Where a row reaches the pane's width, it and the rows after it are
    /// read as one line, each later row without its indent, and the rules marked `wraps` are tried on that. A
    /// hit that crosses a row break is replaced by its marker where it starts; the rows it ran over stay as
    /// rows, emptied of it. Hits inside one row are left to the rules below.
    ///
    /// Only a row as wide as the pane counts, so two rows that merely follow each other are never joined; with
    /// no width given nothing is. `reaches` says which rows those are (`rowsThatReach`).
    static func wrappedOut(_ text: String, reaches: [Bool], _ count: inout Int) -> String {
        var rows = text.components(separatedBy: "\n")
        // the passes before this one keep every row break, so the rows are still the ones `reaches` is about
        guard rows.count > 1, reaches.count == rows.count else { return text }
        var first = 0
        while first < rows.count - 1 {
            guard reaches[first] else { first += 1; continue }
            var last = first
            while last < rows.count - 1, reaches[last] { last += 1 }
            // rows first...last as one line; where each row's part starts in it, and how much indent it lost
            var joined = ""
            var starts: [Int] = []
            var indents: [Int] = []
            for r in first...last {
                let row = rows[r] as NSString
                var indent = 0
                if r > first { while indent < row.length, row.character(at: indent) == 0x20 { indent += 1 } }
                starts.append((joined as NSString).length)
                indents.append(indent)
                joined += row.substring(from: indent)
            }
            let line = joined as NSString
            var hits: [(range: NSRange, kind: String)] = []
            for rule in rules where rule.wraps {
                for m in rule.regex.matches(in: joined, range: NSRange(location: 0, length: line.length)) {
                    let end = m.range.location + m.range.length
                    guard starts.dropFirst().contains(where: { m.range.location < $0 && $0 < end }) else { continue }
                    guard !hits.contains(where: { NSIntersectionRange($0.range, m.range).length > 0 }) else { continue }
                    hits.append((m.range, rule.kind))
                }
            }
            // from the last hit back, so the places of the earlier ones hold
            for hit in hits.sorted(by: { $0.range.location > $1.range.location }) {
                let end = hit.range.location + hit.range.length
                let from = starts.lastIndex(where: { $0 <= hit.range.location })!
                let to = starts.lastIndex(where: { $0 < end })!
                for k in from...to {
                    let row = rows[first + k] as NSString
                    // this row's part of the hit, in the row's own places
                    let lower = max(hit.range.location, starts[k]) - starts[k] + indents[k]
                    let upper = min(end, k + 1 < starts.count ? starts[k + 1] : line.length) - starts[k] + indents[k]
                    rows[first + k] = row.substring(to: lower) + (k == from ? "[redacted: \(hit.kind)]" : "") + row.substring(from: upper)
                }
                count += 1
            }
            first = last
        }
        return rows.joined(separator: "\n")
    }

    // MARK: known secret shapes

    struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// A capture group kept in front of the marker (`Authorization: Bearer `, `NAME=`), 0 for none.
        let keep: Int
        /// A key with a fixed shape: also looked for across a row break (`wrappedOut`).
        let wraps: Bool

        init(_ kind: String, _ pattern: String, keep: Int = 0, wraps: Bool = false) {
            self.kind = kind
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.keep = keep
            self.wraps = wraps
        }

        func apply(_ text: String, _ count: inout Int) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            let out = NSMutableString(string: text)
            for m in matches.reversed() {
                let kept = keep > 0 && m.range(at: keep).location != NSNotFound ? ns.substring(with: m.range(at: keep)) : ""
                // the rows of the part replaced, not of the kept part, so no row is added or lost
                let rows = ns.substring(with: m.range).dropFirst(kept.count).filter { $0 == "\n" }.count
                out.replaceCharacters(in: m.range, with: kept + "[redacted: \(kind)]" + String(repeating: "\n", count: rows))
                count += 1
            }
            return out as String
        }
    }

    /// Order matters where shapes overlap: an Anthropic key also looks like an OpenAI one, and a whole
    /// private key block goes before the rule for the tail of one cut off at the top of the read.
    static let rules: [Rule] = [
        Rule("private key", #"-----BEGIN[A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----[\s\S]*?(?:-----END[A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----|\z)"#),
        Rule("private key", #"(?m)(?:^[A-Za-z0-9+/=]{16,}\n)+-----END[A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"#),
        Rule("aws access key", #"\b(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b"#, wraps: true),
        Rule("github token", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})\b"#, wraps: true),
        Rule("gitlab token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#, wraps: true),
        Rule("anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#, wraps: true),
        Rule("openai key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#, wraps: true),
        Rule("stripe key", #"\b[sr]k_(?:live|test)_[A-Za-z0-9]{16,}"#, wraps: true),
        Rule("google api key", #"\bAIza[A-Za-z0-9_\-]{35}"#, wraps: true),
        Rule("npm token", #"\bnpm_[A-Za-z0-9]{36}"#, wraps: true),
        Rule("sendgrid key", #"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#, wraps: true),
        Rule("hugging face token", #"\bhf_[A-Za-z0-9]{30,}\b"#, wraps: true),
        Rule("slack token", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#, wraps: true),
        Rule("slack webhook", #"https://hooks\.slack\.com/(?:services|workflows)/[A-Za-z0-9+/_\-]{20,}"#, wraps: true),
        Rule("jwt", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#, wraps: true),
        Rule("bearer token", #"(?i)(\bauthorization\s*[:=]\s*["']?bearer\s+)(?!\[(?:dojo token|redacted))[A-Za-z0-9._~+/=\-]{8,}"#, keep: 1),
        Rule("url credentials", #"(?i)(\b[a-z][a-z0-9+.\-]{1,20}://)(?!\[(?:dojo token|redacted))[^\s:/@]+:[^\s@/]+(?=@)"#, keep: 1),
        // curl -u name:password, in the forms curl takes: after a blank or attached to -u, with no name, and
        // in quotes, where the password runs to the closing quote and may have blanks in it. Without quotes
        // it ends at a blank or at a shell's separator, which is never taken; a backslash and the character
        // after it are part of it, as the shell reads them ("\;secret" gives curl ";secret"). The name stays.
        Rule("password", #"(?i)(\bcurl\b[^\n]*?[ \t](?:-u[ \t]*|--user[ \t=]+)'[^':\n]*:)(?!\[(?:dojo token|redacted))[^'\n]+(?=')"#, keep: 1),
        Rule("password", #"(?i)(\bcurl\b[^\n]*?[ \t](?:-u[ \t]*|--user[ \t=]+)"[^":\n]*:)(?!\[(?:dojo token|redacted))(?:[^"\\\n]|\\.)+(?=")"#, keep: 1),
        Rule("password", #"(?i)(\bcurl\b[^\n]*?[ \t](?:-u[ \t]*|--user[ \t=]+)[^\s:"']*:)(?!\[(?:dojo token|redacted))(?:\\.|[^\s"';&|)\\])+"#, keep: 1),
        // NAME=value where the name says what it holds; not MAX_TOKENS, not a bare number (which also ends at
        // a shell's separator, and never takes it). The name may be the word alone (PASSWORD=, API_KEY=): the
        // part in front of it is optional (D35.4). A quoted value is read to its closing quote, whatever
        // blanks it holds; in double quotes a quote after a backslash is not the end.
        Rule("secret",
             #"(?im)((?:^|[ \t])(?:export[ \t]+)?(?:[A-Z_][A-Z0-9_]*)?(?:TOKEN(?!S)|SECRET|PASSWORD|PASSWD|API_?KEY)[A-Z0-9_]*[ \t]*=[ \t]*)(?!\[(?:dojo token|redacted))(?![0-9]+(?:[\s;&|)]|$))(?:"(?:[^"\\\n]|\\.){4,}"|'[^'\n]{4,}'|["']?[^\s"']{4,}["']?)"#,
             keep: 1),
        // The same names as a YAML or JSON key: `password: value` where the key starts its row, and a quoted
        // `"api_key": "value"` after a brace or a comma. Not `token: String` in the middle of a row of code,
        // and not a type on a row of its own: one bare word of a type's letters that ends its row with a
        // comma or a semicolon (`token: String,`, `password: string;`), or a common type name alone. A value
        // that is exactly such a word passes with them.
        Rule("secret",
             #"(?im)((?:^[ \t]*(?:-[ \t]+)?["']?(?:[A-Z_][A-Z0-9_\-]*)?(?:TOKEN(?!S)|SECRET|PASSWORD|PASSWD|API[_\-]?KEY)[A-Z0-9_\-]*["']?|[{,][ \t]*["'](?:[A-Z_][A-Z0-9_\-]*)?(?:TOKEN(?!S)|SECRET|PASSWORD|PASSWD|API[_\-]?KEY)[A-Z0-9_\-]*["'])[ \t]*:[ \t]*)(?!\[(?:dojo token|redacted))(?![0-9]+(?:[\s,}]|$))(?![A-Za-z0-9_<>\[\]?.]+[,;][ \t]*$)(?!(?:string|str|int|bool|boolean|number|any|bytes|data|optional<[A-Za-z0-9_.]+>)[?!]?[ \t]*$)(?:"(?:[^"\\\n]|\\.){4,}"|'[^'\n]{4,}'|[^\s"',}]{4,})"#,
             keep: 1),
    ]
}

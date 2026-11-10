import Foundation

/// What `read` hands another pane, with secrets taken out (D21.2, step 2). Always on: the owner chose no
/// switch. The owner's own view of a pane is never changed; only the text that leaves the bus is.
///
/// Two passes. Every live bus token is replaced exactly, even when the terminal wrapped it across two rows:
/// the bus knows them all, so that one is a guarantee. Then the known secret shapes in `rules`, the short
/// list below, after the rule sets of gitleaks and detect-secrets. A pattern list misses things, so this is
/// a backstop; who may read at all is the primary control (step 3, roles).
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

    public static func apply(_ text: String, tokens: [String]) -> Outcome {
        var count = 0
        var out = tokensOut(text, tokens, &count)
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

    // MARK: known secret shapes

    struct Rule {
        let kind: String
        let regex: NSRegularExpression
        /// A capture group kept in front of the marker (`Authorization: Bearer `, `NAME=`), 0 for none.
        let keep: Int

        init(_ kind: String, _ pattern: String, keep: Int = 0) {
            self.kind = kind
            self.regex = try! NSRegularExpression(pattern: pattern)
            self.keep = keep
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
        Rule("aws access key", #"\b(?:AKIA|ASIA|ABIA|ACCA)[A-Z0-9]{16}\b"#),
        Rule("github token", #"\b(?:gh[pousr]_[A-Za-z0-9]{36,255}|github_pat_[A-Za-z0-9_]{22,255})\b"#),
        Rule("anthropic key", #"\bsk-ant-[A-Za-z0-9_\-]{20,}"#),
        Rule("openai key", #"\bsk-(?:proj-|svcacct-|admin-)?[A-Za-z0-9_\-]{20,}"#),
        Rule("hugging face token", #"\bhf_[A-Za-z0-9]{30,}\b"#),
        Rule("slack token", #"\bxox[abposr]-[A-Za-z0-9\-]{10,}"#),
        Rule("slack webhook", #"https://hooks\.slack\.com/(?:services|workflows)/[A-Za-z0-9+/_\-]{20,}"#),
        Rule("jwt", #"\beyJ[A-Za-z0-9_\-]{10,}\.eyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        Rule("bearer token", #"(?i)(\bauthorization\s*[:=]\s*["']?bearer\s+)(?!\[(?:dojo token|redacted))[A-Za-z0-9._~+/=\-]{8,}"#, keep: 1),
        Rule("url credentials", #"(?i)(\b[a-z][a-z0-9+.\-]{1,20}://)(?!\[(?:dojo token|redacted))[^\s:/@]+:[^\s@/]+(?=@)"#, keep: 1),
        // NAME=value where the name says what it holds; not MAX_TOKENS, not a bare number.
        Rule("secret",
             #"(?im)((?:^|[ \t])(?:export[ \t]+)?[A-Z_][A-Z0-9_]*(?:TOKEN(?!S)|SECRET|PASSWORD|PASSWD|API_?KEY)[A-Z0-9_]*[ \t]*=[ \t]*)(?!\[(?:dojo token|redacted))(?![0-9]+(?:\s|$))["']?[^\s"']{4,}["']?"#,
             keep: 1),
    ]
}

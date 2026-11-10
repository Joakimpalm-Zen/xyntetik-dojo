import Foundation
import Testing
@testable import XHSCore

/// Redaction in `read` (D21.2, step 2). Every sample secret is put together from pieces at run time, so
/// this file holds nothing a secret scanner would take for a real one.
@Suite struct RedactTests {
    static let token = String(repeating: "0a1b2c3d", count: 6)   // a bus token's shape: 48 hex characters

    static func chars(_ unit: String, _ count: Int) -> String {
        String(String(repeating: unit, count: count / unit.count + 1).prefix(count))
    }

    func redact(_ text: String) -> Redact.Outcome { Redact.apply(text, tokens: [Self.token]) }

    @Test func aLiveBusTokenIsReplacedExactly() {
        let r = redact("token " + Self.token + " here")
        #expect(r.text == "token [dojo token] here")
        #expect(r.count == 1)
    }

    @Test func aTokenTheTerminalWrappedAcrossTwoRowsIsFoundToo() {
        let t = Self.token
        let r = redact("echo " + t.prefix(20) + "\n" + t.dropFirst(20) + " done")
        #expect(r.text == "echo [dojo token]\n done")
        #expect(r.count == 1)
    }

    @Test func aTokenInAnAssignmentCountsOnce() {
        let r = redact("DOJO_TOKEN=" + Self.token)
        #expect(r.text == "DOJO_TOKEN=[dojo token]")
        #expect(r.count == 1)
    }

    static let shapes: [(String, String)] = [
        ("AK" + "IA" + "ABCDEFGHIJKLMNOP", "aws access key"),
        ("gh" + "p_" + chars("a1B2", 36), "github token"),
        ("github" + "_pat_" + chars("a1_B", 40), "github token"),
        ("sk-" + "ant-" + "api03-" + chars("aB3-", 48), "anthropic key"),
        ("sk-" + "proj-" + chars("Zx9_", 48), "openai key"),
        ("hf" + "_" + chars("aBcD", 34), "hugging face token"),
        ("xo" + "xb-" + "1234567890-" + chars("ab12", 24), "slack token"),
        ("https://hooks.slack.com/" + "services/" + "T0000/B0000/" + chars("aB9", 24), "slack webhook"),
        ("ey" + "J" + chars("hbGc", 16) + ".ey" + "J" + chars("zdWI", 16) + "." + chars("SflK", 16), "jwt"),
    ]

    @Test(arguments: shapes)
    func eachKnownShapeIsTakenOut(sample: String, kind: String) {
        let r = redact("before " + sample + " after")
        #expect(r.text == "before [redacted: \(kind)] after", "\(kind)")
        #expect(r.count == 1)
    }

    @Test func aBearerHeaderKeepsItsNameAndLosesItsValue() {
        let r = redact("curl -H 'Authorization: Bearer " + Self.chars("q1W2", 24) + "' https://x")
        #expect(r.text == "curl -H 'Authorization: Bearer [redacted: bearer token]' https://x")
    }

    @Test func credentialsInAURLGoAndTheHostStays() {
        let r = redact("psql postgres://admin:" + "hunter2" + "pass" + "@db.example:5432/app")
        #expect(r.text == "psql postgres://[redacted: url credentials]@db.example:5432/app")
    }

    @Test func anAssignmentWhoseNameSaysSecretKeepsTheName() {
        let value = Self.chars("p4Ss", 16)
        for (line, name) in [("export DB_PASSWORD=" + value, "export DB_PASSWORD="),
                             ("SERVICE_API_KEY='" + value + "'", "SERVICE_API_KEY="),
                             ("$ GITHUB_TOKEN = " + value, "$ GITHUB_TOKEN = "),
                             ("client_secret=" + value, "client_secret=")] {
            let r = redact(line)
            #expect(r.text == name + "[redacted: secret]", "\(line)")
            #expect(r.count == 1)
        }
    }

    @Test func aPrivateKeyKeepsItsRows() {
        let block = ["-----BEGIN OPENSSH PRIVATE KEY-----", Self.chars("b3Bl", 40), Self.chars("AAAA", 40),
                     "-----END OPENSSH PRIVATE KEY-----"].joined(separator: "\n")
        let r = redact("cat ~/.ssh/id\n" + block + "\n$ ")
        let rows = r.text.components(separatedBy: "\n")
        #expect(rows.count == 6)   // the same six rows: one line, four of the key, the prompt
        #expect(rows[0] == "cat ~/.ssh/id")
        #expect(rows[1] == "[redacted: private key]")
        let keyRowsEmpty = rows[2...4].allSatisfy { $0.isEmpty }
        #expect(keyRowsEmpty)
        #expect(rows[5] == "$ ")
        #expect(!r.text.contains("b3Bl"))
    }

    @Test func aPrivateKeyCutOffAtEitherEdgeOfTheReadGoesToo() {
        let tail = [Self.chars("QyNT", 40), Self.chars("UxOQ", 40), "-----END RSA PRIVATE KEY-----", "$ ls"]
        let r = redact(tail.joined(separator: "\n"))
        #expect(r.text == "[redacted: private key]\n\n\n$ ls")
        let head = redact("-----BEGIN PRIVATE KEY-----\n" + Self.chars("MIIE", 40))
        #expect(head.text == "[redacted: private key]\n")
    }

    @Test func ordinaryTextIsLeftAlone() {
        let text = [
            "max_tokens=4096", "MAX_TOKENS=4096", "TOKEN_COUNT=12", "PASSWORD=", "the password is in the vault",
            "https://example.com/a/b?c=d", "sk-short", "gh" + "p_short", "Authorization: Basic",
            "commit 1234567890abcdef1234567890abcdef12345678", "ssh user@host",
        ].joined(separator: "\n")
        let r = redact(text)
        #expect(r.text == text)
        #expect(r.count == 0)
    }

    @Test func rowsKeepTheirPlace() {
        let text = ["one", "key " + "gh" + "p_" + Self.chars("a1B2", 36), "three", "DB_PASSWORD=" + Self.chars("x9", 12),
                    "five"].joined(separator: "\n")
        let r = redact(text)
        let rows = r.text.components(separatedBy: "\n")
        #expect(rows == ["one", "key [redacted: github token]", "three", "DB_PASSWORD=[redacted: secret]", "five"])
        #expect(r.count == 2)
    }
}

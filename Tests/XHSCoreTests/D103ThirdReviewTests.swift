import Foundation
import Testing
@testable import XHSCore

/// The reviewer's third read of #103: the inputs that need no terminal, as tests. The terminal's own part
/// of the second finding and the first finding are in XHSAppTests (D103ThirdReviewAppTests).
@Suite struct D103ThirdReviewTests {
    func redact(_ text: String, width: Int = 0, cells: [Int]? = nil) -> Redact.Outcome {
        Redact.apply(text, tokens: [], width: width, cells: cells)
    }

    /// 2. After a narrowing, a row of the text can hold cells past the pane's right edge: the terminal keeps
    /// them, and the text read returns has them, while the terminal's count stops at the edge. Such a row
    /// counts by its characters too, whichever is more: 80 characters count 80.
    @Test func aRowCountsAtLeastItsCharacters() {
        let first = ">" + String(repeating: " ", count: 39) + String(repeating: "x", count: 29) + " gl" + "pat-AAAA"
        let second = String(repeating: "A", count: 16)
        let text = first + "\n" + second
        #expect(Redact.rowsThatReach(40, text, cells: [1, 16]) == [true, false])
        #expect(redact(text, width: 40, cells: [1, 16]).text
            == ">" + String(repeating: " ", count: 39) + String(repeating: "x", count: 29) + " [redacted: gitlab token]\n")
        // the terminal's count still decides where it is the larger: a row of wide characters
        let wide = String(repeating: "界", count: 16) + " gl" + "pat-A"
        #expect(Redact.rowsThatReach(40, wide + "\n" + String(repeating: "A", count: 19), cells: [40, 19]) == [true, false])
    }

    /// 3. A backslash and the character after it are part of curl's unquoted password: the shell gives curl
    /// ";secret" for "\;secret". The first blank or separator without a backslash before it ends it.
    @Test func anEscapedSeparatorIsPartOfCurlsPassword() {
        #expect(redact(#"curl -u alice:\;secret https://example.invalid"#).text == "curl -u alice:[redacted: password] https://example.invalid")
        #expect(redact(#"curl -u alice:\&secret https://example.invalid"#).text == "curl -u alice:[redacted: password] https://example.invalid")
        #expect(redact(#"curl -u alice:pass\ word https://example.invalid"#).text == "curl -u alice:[redacted: password] https://example.invalid")
        #expect(redact(#"curl -ualice:long\;secret;printf done"#).text == "curl -ualice:[redacted: password];printf done")
        // the separators without a backslash still end it, and are never taken
        #expect(redact("curl -ualice:long-secret;printf done").text == "curl -ualice:[redacted: password];printf done")
        #expect(redact("curl -u alice:long-secret && echo ok").text == "curl -u alice:[redacted: password] && echo ok")
    }
}

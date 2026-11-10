import Foundation
import Testing
@testable import XHSCore

/// D29: a resumed Claude pane takes its model from the transcript, since the resume's SessionStart names none.
@Suite struct TranscriptTests {
    private func file(_ lines: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        return url.path
    }

    private func assistant(_ model: String) -> String {
        #"{"type":"assistant","message":{"model":"\#(model)","role":"assistant","content":[]}}"#
    }

    @Test func theLastAssistantLineNamesTheModel() throws {
        let path = try file([#"{"type":"user","message":{"role":"user","content":"hi"}}"#, assistant("claude-opus-5-5"),
                             #"{"type":"user","message":{"role":"user","content":"again"}}"#, assistant("claude-fable-5-2"),
                             #"{"type":"last-prompt"}"#, "not json at all"])
        #expect(Transcript.lastModel(at: path) == "claude-fable-5-2")
    }

    @Test func claudeCodesOwnNotesAndEmptyNamesAreSkipped() throws {
        let path = try file([assistant("claude-sonnet-5-5"), assistant("<synthetic>"), assistant("")])
        #expect(Transcript.lastModel(at: path) == "claude-sonnet-5-5")
    }

    @Test func noFileOrNoAnswerIsNil() throws {
        #expect(Transcript.lastModel(at: "/nonexistent/transcript.jsonl") == nil)
        #expect(Transcript.lastModel(at: try file([#"{"type":"user","message":{"content":"hi"}}"#])) == nil)
    }

    /// Only the tail is read, and the line it cuts into is not taken for a whole one.
    @Test func aLargeTranscriptIsReadFromItsEnd() throws {
        let filler = #"{"type":"user","message":{"content":"\#(String(repeating: "x", count: 1000))"}}"#
        let lines = [assistant("claude-old-1")] + Array(repeating: filler, count: Transcript.tailBytes / 1000 + 50) + [assistant("claude-new-2")]
        #expect(Transcript.lastModel(at: try file(lines)) == "claude-new-2")
        let early = [assistant("claude-old-1")] + Array(repeating: filler, count: Transcript.tailBytes / 1000 + 50)
        #expect(Transcript.lastModel(at: try file(early)) == nil)
    }
}

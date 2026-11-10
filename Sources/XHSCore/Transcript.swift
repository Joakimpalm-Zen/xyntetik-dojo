import Foundation

/// D29: the model a Claude Code session last answered with, read from its transcript. Since Claude Code 2.1.322
/// the SessionStart hook names the model on a fresh start and not on a resume, and a reopened pane is a resume.
/// Each assistant line of the transcript carries `message.model`, and every hook carries `transcript_path`.
public enum Transcript {
    /// How much of the end of the file is read: the last answer is near the end, and a transcript can be large.
    public static let tailBytes = 512 * 1024

    /// The model of the last assistant line in the tail of the transcript at `path`, or nil when there is none.
    /// Lines that do not parse are skipped, and so is `<synthetic>`, which Claude Code writes for its own notes.
    public static func lastModel(at path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return nil }
        var lines = data.split(separator: UInt8(ascii: "\n"))
        // Reading from the middle of the file, the first line is cut.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>" else { continue }
            return model
        }
        return nil
    }
}

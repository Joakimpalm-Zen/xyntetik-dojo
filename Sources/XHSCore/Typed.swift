import Foundation

/// D21.5: typed messages. Four shapes the panes already wrote by hand (an assignment, a report on a pull request, a
/// merge notice, a bug report), checked by the bus and delivered as text that every harness reads alike: a first line
/// with the type and what it is about, then one indented `key: value` line per field, in the schema's order. Free text
/// is unchanged. A typed message is information for a peer like any other, never the owner's approval.
public enum Typed {
    /// What a field must look like.
    public enum Check: Equatable, Sendable {
        /// One line of text.
        case text
        /// A pull request number (a leading # is taken off).
        case number
        /// A commit SHA, 7 to 40 hex digits.
        case sha
        /// Checks as `name=state` words, the state pass, fail, pending or skipped.
        case checks
        /// yes, no or unknown.
        case yesNo
    }

    public struct Field: Equatable, Sendable {
        public let name: String
        public let required: Bool
        public let check: Check
    }

    private static func f(_ name: String, _ check: Check = .text, required: Bool = true) -> Field {
        Field(name: name, required: required, check: check)
    }

    /// The four types and their fields, in the order the card shows them.
    public static let schemas: [(type: String, fields: [Field])] = [
        ("assign", [f("item"), f("what"), f("next", required: false), f("by", required: false)]),
        ("report", [f("repo"), f("pr", .number), f("head", .sha), f("checks", .checks), f("mergeable", .yesNo),
                    f("note", required: false)]),
        ("merged", [f("repo"), f("pr", .number), f("sha", .sha), f("item", required: false), f("note", required: false)]),
        ("bug", [f("command"), f("observed"), f("expected"), f("cause", required: false), f("where", required: false)]),
    ]

    public static var types: [String] { schemas.map(\.type) }

    public static func fields(of type: String) -> [Field]? { schemas.first { $0.type == type }?.fields }

    /// The message as it is typed into the pane, after the `[from: ...]` tag the bus adds, and the fields as checked;
    /// or what is wrong, naming the field. A value is one line; numbers and SHAs are written the one way.
    public static func render(type: String, fields raw: Any?) -> Result<(text: String, fields: [String: String]), Refusal> {
        guard let schema = fields(of: type) else {
            return .failure(Refusal("unknown type \(type); the types are \(types.joined(separator: ", "))"))
        }
        guard let given = raw as? [String: Any] else { return .failure(Refusal("\(type) needs fields, an object")) }
        if let unknown = given.keys.sorted().first(where: { name in !schema.contains { $0.name == name } }) {
            return .failure(Refusal("unknown field \(unknown) for \(type); its fields are \(schema.map(\.name).joined(separator: ", "))"))
        }
        var clean: [String: String] = [:]
        for field in schema {
            let value: String
            switch given[field.name] {
            case let s as String: value = s
            case let n as NSNumber: value = n.stringValue
            case nil: value = ""
            default: return .failure(Refusal("field \(field.name) must be text"))
            }
            if value.contains(where: { $0 == "\n" || $0 == "\r" }) { return .failure(Refusal("field \(field.name) must be one line")) }
            let text = Delivery.sanitize(value)
            if text.isEmpty {
                if field.required { return .failure(Refusal("\(type) needs \(field.name)")) }
                continue
            }
            switch checked(text, field.check) {
            case .some(let ok): clean[field.name] = ok
            case .none: return .failure(Refusal("field \(field.name) is not \(describe(field.check)): \(text)"))
            }
        }
        var lines = [summary(type, clean)]
        for field in schema { if let v = clean[field.name] { lines.append("  \(field.name): \(v)") } }
        return .success((lines.joined(separator: "\n"), clean))
    }

    public struct Refusal: Error, Equatable {
        public let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    /// The first line: the type and what the message is about.
    static func summary(_ type: String, _ f: [String: String]) -> String {
        switch type {
        case "assign": return "assign \(f["item"] ?? "")"
        case "report": return "report \(f["repo"] ?? "") #\(f["pr"] ?? "")"
        case "merged": return "merged \(f["repo"] ?? "") #\(f["pr"] ?? "") as \(String((f["sha"] ?? "").prefix(8)))"
        default: return f["where"].map { "bug in \($0)" } ?? "bug"
        }
    }

    static func checked(_ text: String, _ check: Check) -> String? {
        switch check {
        case .text:
            return text
        case .number:
            let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
            return !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber) ? digits : nil
        case .sha:
            let lower = text.lowercased()
            return (7...40).contains(lower.count) && lower.allSatisfy({ "0123456789abcdef".contains($0) }) ? lower : nil
        case .checks:
            let words = text.split(whereSeparator: { $0 == "," || $0 == " " })
            let states: Set<Substring> = ["pass", "fail", "pending", "skipped"]
            let ok = !words.isEmpty && words.allSatisfy { word in
                let parts = word.split(separator: "=", omittingEmptySubsequences: false)
                return parts.count == 2 && !parts[0].isEmpty && states.contains(parts[1])
                    && parts[0].allSatisfy { $0.isLetter || $0.isNumber || "._/-".contains($0) }
            }
            return ok ? words.joined(separator: ", ") : nil
        case .yesNo:
            let lower = text.lowercased()
            return ["yes", "no", "unknown"].contains(lower) ? lower : nil
        }
    }

    static func describe(_ check: Check) -> String {
        switch check {
        case .text: return "text"
        case .number: return "a pull request number"
        case .sha: return "a commit SHA (7 to 40 hex digits)"
        case .checks: return "checks as name=pass|fail|pending|skipped"
        case .yesNo: return "yes, no or unknown"
        }
    }
}

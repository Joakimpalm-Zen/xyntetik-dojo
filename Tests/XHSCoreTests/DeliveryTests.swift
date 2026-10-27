import Testing
@testable import XHSCore

@Suite struct DeliveryTests {
    @Test func prefixNamesTheSender() {
        #expect(Delivery.line(from: "claude-1", text: "hi") == "[from: claude-1] hi")
    }

    @Test func sanitizeDropsTerminalControls() {
        let hostile = "ok\u{1b}[201~\r\u{1b}]0;title\u{07}\u{9b}31m\u{7f}\tend\u{0}"
        let clean = Delivery.sanitize(hostile)
        #expect(clean == "ok[201~\n]0;title31m end")
        #expect(!clean.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
    }

    @Test func sanitizeNormalisesLineBreaksAndTrims() {
        #expect(Delivery.sanitize("  a\r\nb\rc \n") == "a\nb\nc")
    }

    @Test func withoutBracketedPasteLinesJoin() {
        #expect(Delivery.bytes("a\nb", bracketedPaste: false) == Array("a b".utf8))
    }

    @Test func withBracketedPasteMessageIsOnePaste() {
        #expect(Delivery.bytes("a\nb", bracketedPaste: true) == Array("\u{1b}[200~a\nb\u{1b}[201~".utf8))
    }
}

@Suite struct HookMappingTests {
    @Test(arguments: [
        ("SessionStart", nil, PaneState.idle),
        ("UserPromptSubmit", nil, .running),
        ("PermissionRequest", nil, .prompt),
        ("PostToolUse", nil, .running),
        ("Stop", nil, .idle),
        ("Interrupt", nil, .idle),
        ("Notification", "permission_prompt", .prompt),
        ("Notification", "agent_needs_input", .prompt),
        ("Notification", "elicitation_dialog", .prompt),
        ("Notification", "idle_prompt", .idle),
    ] as [(String, String?, PaneState)])
    func mapsEvents(event: String, type: String?, expected: PaneState) {
        #expect(HookMapping.next(event: event, notificationType: type, current: .running) == expected)
    }

    @Test func otherEventsKeepTheState() {
        #expect(HookMapping.next(event: "PreToolUse", notificationType: nil, current: .running) == nil)
        #expect(HookMapping.next(event: "Notification", notificationType: "auth_success", current: .idle) == nil)
        #expect(HookMapping.next(event: "Notification", notificationType: nil, current: .idle) == nil)
    }
}

@Suite struct NamesTests {
    @Test func nextNameIsFirstFree() {
        #expect(PaneNames.next(for: .claude, taken: []) == "claude-1")
        #expect(PaneNames.next(for: .codex, taken: ["codex-1", "codex-3"]) == "codex-2")
    }

    @Test func userNames() {
        #expect(PaneNames.isValid("reviewer"))
        #expect(PaneNames.isValid("pi-2.local"))
        #expect(!PaneNames.isValid(""))
        #expect(!PaneNames.isValid("-x"))
        #expect(!PaneNames.isValid("Has Space"))
        #expect(!PaneNames.isValid(String(repeating: "a", count: 25)))
    }

    @Test func hosts() {
        #expect(Hosts.isValid("box"))
        #expect(Hosts.isValid("user@lab.example.org"))
        #expect(!Hosts.isValid("-oProxyCommand=evil"))
        #expect(!Hosts.isValid("box; rm -rf"))
        #expect(!Hosts.isValid(""))
    }
}

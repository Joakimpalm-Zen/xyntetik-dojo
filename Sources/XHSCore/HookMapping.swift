/// Maps harness hook events to pane states.
/// Claude Code and Codex send their own hook events; the pi extension sends the same names.
public enum HookMapping {
    public static let promptNotifications: Set<String> = ["permission_prompt", "elicitation_dialog", "agent_needs_input"]

    /// The state after an event, or nil when the event does not change it.
    public static func next(event: String, notificationType: String?, current: PaneState) -> PaneState? {
        switch event {
        case "SessionStart": return .idle
        case "UserPromptSubmit": return .running
        case "PermissionRequest": return .prompt
        case "PostToolUse", "PostToolUseFailure": return .running
        case "Stop", "Interrupt": return .idle
        case "Notification":
            guard let type = notificationType else { return nil }
            if promptNotifications.contains(type) { return .prompt }
            if type == "idle_prompt" { return .idle }
            return nil
        default: return nil
        }
    }
}

/// What a harness shows when it is ready and nothing is going on, for a harness that does not report its
/// session start before the first prompt. Codex creates its session, and sends SessionStart, with the first
/// prompt, so a fresh Codex pane would wait at `starting` for the owner to type something. Runner prints
/// its listening line once the model is loaded.
public enum IdleFingerprint {
    public static func text(for kind: HarnessKind) -> String? {
        switch kind {
        case .codex: return "Ask Codex to do anything"
        case .runner: return "server listening on"
        default: return nil
        }
    }
}

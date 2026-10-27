import Foundation

/// A word in a shell command line: quoted, or inserted as written (for $HOME expansions).
public enum ShellWord: Equatable, Sendable {
    case literal(String)
    case raw(String)

    public var rendered: String {
        switch self {
        case .literal(let s): return Shell.quote(s)
        case .raw(let s): return s
        }
    }
}

public enum Shell {
    /// POSIX single-quote quoting.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-").contains($0) }) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func line(_ words: [ShellWord]) -> String {
        words.map(\.rendered).joined(separator: " ")
    }

    /// A TOML basic string.
    public static func toml(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// How to start a pane: the program, its arguments and the environment it adds.
public struct LaunchPlan: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
}

/// Builds the command for each harness, local or over ssh.
public enum Launcher {
    public static let defaultPort = 7788
    public static let runnerURL = "http://127.0.0.1:8080/v1"
    /// The shim as the harness runs it; $HOME is expanded on the host the harness runs on.
    public static let shimCommand = #"exec python3 "$HOME/.xhs/xhs-mcp.py""#

    /// Claude Code settings passed with --settings: http hooks that report state to the bus.
    public static func claudeSettings(port: Int) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/hook",
            "timeout": 5,
            "headers": ["X-XHS-Token": "$XHS_TOKEN"],
            "allowedEnvVars": ["XHS_TOKEN"],
        ]
        let group: [[String: Any]] = [["hooks": [hook]]]
        return ["hooks": [
            "SessionStart": group,
            "UserPromptSubmit": group,
            "PermissionRequest": group,
            "PostToolUse": group,
            "Stop": group,
            "Notification": [["matcher": "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog", "hooks": [hook]]],
        ]]
    }

    /// Claude Code MCP config passed with --mcp-config.
    public static func claudeMCP() -> [String: Any] {
        ["mcpServers": ["xhs": ["command": "sh", "args": ["-c", shimCommand]]]]
    }

    public static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The harness command line, the same locally and remotely.
    public static func harnessWords(kind: HarnessKind, paneName: String, port: Int, runnerModel: String?) -> [ShellWord] {
        let prompt = PeerRule.launchPrompt(paneName: paneName)
        switch kind {
        case .claude:
            return [.literal("claude"),
                    .literal("--settings"), .literal(json(claudeSettings(port: port))),
                    .literal("--append-system-prompt"), .literal(prompt),
                    .literal("--mcp-config"), .literal(json(claudeMCP()))]
        case .codex:
            // MCP server and hooks live in ~/.codex/config.toml (written by "xhs install").
            return [.literal("codex"), .literal("-c"), .literal("developer_instructions=" + Shell.toml(prompt))]
        case .pi:
            var words: [ShellWord] = [.literal("pi"), .literal("-e"), .raw(#""$HOME/.xhs/xhs-pi.ts""#),
                                      .literal("--provider"), .literal("runner")]
            if let runnerModel { words += [.literal("--model"), .literal(runnerModel)] }
            return words + [.literal("--append-system-prompt"), .literal(prompt)]
        case .shell:
            return [.literal("/bin/sh"), .literal("-c"), .literal("echo ok")]
        }
    }

    /// The plan for a pane. Local panes run in the owner's login shell so PATH matches their terminal.
    /// Remote panes run `ssh -t -R port:127.0.0.1:port host` with the same harness command in the remote login shell.
    public static func plan(kind: HarnessKind, paneName: String, host: String?, port: Int, token: String,
                            runnerModel: String?, loginShell: String) -> LaunchPlan {
        let env = ["XHS_PANE": paneName, "XHS_PORT": String(port), "XHS_TOKEN": token]
        if kind == .shell {
            return LaunchPlan(executable: "/bin/sh", args: ["-c", "echo ok"], environment: env)
        }
        let harness = harnessWords(kind: kind, paneName: paneName, port: port, runnerModel: runnerModel)
        let path: ShellWord = .raw(#"PATH="$HOME/.xhs/bin:$PATH""#)
        guard let host, !host.isEmpty else {
            let line = "exec " + Shell.line([.literal("env"), path] + harness)
            return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", line], environment: env)
        }
        let assignments: [ShellWord] = ["XHS_PANE", "XHS_PORT", "XHS_TOKEN"].map { .literal("\($0)=\(env[$0]!)") }
        let inner = "exec " + Shell.line([.literal("env")] + assignments + [path] + harness)
        let remote = #"exec "$SHELL" -l -i -c "# + Shell.quote(inner)
        let ssh = sshWords(host: host, port: port, remoteCommand: remote)
        return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", "exec " + Shell.line(ssh)], environment: env)
    }

    /// ssh with a reverse tunnel so the shim on the remote host reaches the bus at 127.0.0.1:port there.
    public static func sshWords(host: String, port: Int, remoteCommand: String) -> [ShellWord] {
        [.literal("ssh"), .literal("-t"), .literal("-R"), .literal("\(port):127.0.0.1:\(port)"),
         .literal(host), .literal(remoteCommand)]
    }

    /// What a local pi pane shows when Runner does not answer.
    public static func runnerOfflinePlan() -> LaunchPlan {
        let message = "Runner is not answering at \(runnerURL).\\nStart it with: runner -m model.gguf --serve\\nThen close this pane and add pi again.\\n"
        return LaunchPlan(executable: "/bin/sh", args: ["-c", "printf '\(message)'"], environment: [:])
    }

    /// The first model id from Runner's GET /v1/models response.
    public static func firstModelID(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["data"] as? [[String: Any]] else { return nil }
        return models.compactMap { $0["id"] as? String }.first { !$0.isEmpty }
    }

    /// Asks Runner for its models; nil when it does not answer in two seconds.
    public static func fetchRunnerModel() async -> String? {
        var request = URLRequest(url: URL(string: runnerURL + "/models")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return firstModelID(data)
    }
}

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

/// The shell an ssh host hands a remote command to.
public enum RemoteShell: Equatable, Sendable {
    /// A POSIX login shell: the harness runs in `"$SHELL" -l -i -c`.
    case posix
    /// Windows OpenSSH with cmd.exe as its shell: the harness runs in MSYS2 bash at C:\msys64.
    case windows

    /// The command the app runs over ssh before a remote pane starts.
    /// cmd.exe expands %OS% to Windows_NT; a POSIX shell echoes it as written.
    public static let probe = "echo %OS%"

    public static func detect(probeOutput: String) -> RemoteShell {
        probeOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Windows_NT") ? .windows : .posix
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

    /// Claude Code settings passed with --settings: hooks that report state to the bus.
    /// SessionStart is a command hook through the shim: Claude Code does not run http hooks for that event.
    public static func claudeSettings(port: Int) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/hook",
            "timeout": 5,
            "headers": ["X-XHS-Token": "$XHS_TOKEN"],
            "allowedEnvVars": ["XHS_TOKEN"],
        ]
        let group: [[String: Any]] = [["hooks": [hook]]]
        let command: [String: Any] = ["type": "command", "command": shimCommand.replacingOccurrences(of: "exec ", with: "") + " hook", "timeout": 5]
        return ["hooks": [
            "SessionStart": [["hooks": [command]]],
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
            // Owner default: no permission prompts in a supervised pane.
            return [.literal("claude"), .literal("--dangerously-skip-permissions"),
                    .literal("--settings"), .literal(json(claudeSettings(port: port))),
                    .literal("--append-system-prompt"), .literal(prompt),
                    .literal("--mcp-config"), .literal(json(claudeMCP()))]
        case .codex:
            // MCP server and hooks live in ~/.codex/config.toml (written by "xhs install").
            // Owner default: --yolo (no approvals, no sandbox); the hook-trust bypass
            // means the pane's state hooks run without a /hooks confirmation.
            return [.literal("codex"), .literal("--yolo"), .literal("--dangerously-bypass-hook-trust"),
                    .literal("-c"), .literal("developer_instructions=" + Shell.toml(prompt))]
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
    /// A Windows host (cmd.exe over OpenSSH) runs the same inner command in MSYS2 bash; see `windowsRemoteCommand`.
    public static func plan(kind: HarnessKind, paneName: String, host: String?, port: Int, token: String,
                            runnerModel: String?, loginShell: String, remoteShell: RemoteShell = .posix) -> LaunchPlan {
        let env = ["XHS_PANE": paneName, "XHS_PORT": String(port), "XHS_TOKEN": token]
        let local = host == nil || host!.isEmpty
        if kind == .shell, local {
            return LaunchPlan(executable: "/bin/sh", args: ["-c", "echo ok"], environment: env)
        }
        let harness = harnessWords(kind: kind, paneName: paneName, port: port, runnerModel: runnerModel)
        let path: ShellWord = .raw(#"PATH="$HOME/.xhs/bin:$PATH""#)
        guard let host, !local else {
            let line = "exec " + Shell.line([.literal("env"), path] + harness)
            return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", line], environment: env)
        }
        let assignments: [ShellWord] = ["XHS_PANE", "XHS_PORT", "XHS_TOKEN"].map { .literal("\($0)=\(env[$0]!)") }
        let inner = "exec " + Shell.line([.literal("env")] + assignments + [path] + harness)
        let remote: String
        switch remoteShell {
        case .posix: remote = #"exec "$SHELL" -l -i -c "# + Shell.quote(inner)
        case .windows: remote = windowsRemoteCommand(inner: inner)
        }
        let ssh = sshWords(host: host, port: port, remoteCommand: remote)
        return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", "exec " + Shell.line(ssh)], environment: env)
    }

    /// MSYS2's bash on a Windows host. The standard MSYS2 install location.
    public static let msysBash = #"C:\msys64\usr\bin\bash.exe"#

    /// The remote command for a Windows host, parsed by cmd.exe and then by bash.exe.
    /// The inner POSIX line travels as base64 so that cmd.exe never sees a quote, a pipe or a percent sign
    /// from it. `^` escapes the characters cmd.exe would otherwise act on, and `\"` is a quote for bash.exe.
    /// MSYS2_PATH_TYPE=inherit keeps the user's Windows PATH (claude, codex, python) in the login shell.
    public static func windowsRemoteCommand(inner: String) -> String {
        let encoded = Data(inner.utf8).base64EncodedString()
        return "set MSYS2_PATH_TYPE=inherit&& " + msysBash
            + #" -lc "eval \"$^(echo "# + encoded + #" ^| base64 -d^)\"""#
    }

    /// The inner command a Windows remote command carries, for tests and troubleshooting.
    public static func windowsInnerCommand(_ remote: String) -> String? {
        guard let start = remote.range(of: "echo "), let end = remote.range(of: " ^|", range: start.upperBound..<remote.endIndex),
              let data = Data(base64Encoded: String(remote[start.upperBound..<end.lowerBound])) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `ssh host 'echo %OS%'` without a tty, to find out which shell the host runs commands in.
    public static func probeWords(host: String) -> [ShellWord] {
        [.literal("ssh"), .literal("-o"), .literal("BatchMode=yes"), .literal("-o"), .literal("ConnectTimeout=5"),
         .literal(host), .literal(RemoteShell.probe)]
    }

    /// Runs the probe; `.posix` when the host does not answer (the pane then shows the ssh error).
    public static func probeRemoteShell(host: String) async -> RemoteShell {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = probeWords(host: host).dropFirst().compactMap { if case .literal(let s) = $0 { return s } else { return nil } }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return .posix }
        let output: String = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
        return RemoteShell.detect(probeOutput: output)
    }

    /// ssh with a reverse tunnel so the shim on the remote host reaches the bus at 127.0.0.1:port there.
    public static func sshWords(host: String, port: Int, remoteCommand: String) -> [ShellWord] {
        [.literal("ssh"), .literal("-t"), .literal("-R"), .literal("\(port):127.0.0.1:\(port)"),
         .literal(host), .literal(remoteCommand)]
    }

    /// The environment a pane's process gets: the app's own, minus anything a Claude Code session that
    /// launched the app (`make run` from a session, `open` from its shell) would otherwise hand down.
    /// With those inherited, the pane's Claude thinks it is a child session and stops saving its transcript.
    /// The login shell the pane runs re-sets what the owner's profile exports.
    public static func paneEnvironment(from base: [String: String], adding extra: [String: String]) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("CLAUDE") }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for (key, value) in extra { env[key] = value }
        return env
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

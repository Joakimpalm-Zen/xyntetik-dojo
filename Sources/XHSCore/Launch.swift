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

public enum Shell {    /// A folder as the remote shell should see it: a leading `~` or `~/` is left to the shell to expand,
    /// the rest is quoted; anything else is quoted whole.
    public static func homeQuoted(_ path: String) -> String {
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quote(String(path.dropFirst(2))) }
        return quote(path)
    }


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

/// How to start a pane: the program, its arguments, the environment it adds and, for a local pane,
/// the folder it starts in (nil: the home folder). A remote pane changes folder on its host.
public struct LaunchPlan: Equatable, Sendable {
    public var executable: String
    public var args: [String]
    public var environment: [String: String]
    public var directory: String? = nil
}

/// Builds the command for each harness, local or over ssh.
public enum Launcher {
    public static let defaultPort = 7788
    public static let runnerURL = "http://127.0.0.1:8080/v1"
    /// The tools a pi pane runs with: pi's own four. The bus command dojo runs through bash.
    public static let piTools = "read,bash,edit,write"
    /// Spelled out for the small local models pi runs on: how to answer a peer.
    public static let piReplyHint = "You have no dojo tool, only the bash tool. To answer a [from: <name>] message, run the bash command " +
        "dojo send <name> - <<'EOF' with your reply on the lines after it and EOF on a line of its own, then say what you sent; " +
        "never put the reply in double quotes, a backtick or $( ) inside them would run. " +
        "For web pages use curl -sL: without -L a redirect prints nothing at all. Prefer a site's RSS feed to its HTML."
    /// The shim as the harness runs it; $HOME is expanded on the host the harness runs on.
    public static let shimCommand = #"exec python3 "$HOME/.dojo/dojo-mcp.py""#

    /// Claude Code settings passed with --settings: hooks that report state to the bus.
    /// SessionStart is a command hook through the shim: Claude Code does not run http hooks for that event.
    /// PostModelSwitch (after /model) goes the same way and carries the new model name for the header.
    public static func claudeSettings(port: Int) -> [String: Any] {
        let hook: [String: Any] = [
            "type": "http",
            "url": "http://127.0.0.1:\(port)/hook",
            "timeout": 5,
            "headers": ["X-Dojo-Token": "$DOJO_TOKEN"],
            "allowedEnvVars": ["DOJO_TOKEN"],
        ]
        let group: [[String: Any]] = [["hooks": [hook]]]
        let command: [String: Any] = ["type": "command", "command": shimCommand.replacingOccurrences(of: "exec ", with: "") + " hook", "timeout": 5]
        return ["hooks": [
            "SessionStart": [["hooks": [command]]],
            "PostModelSwitch": [["hooks": [command]]],
            "UserPromptSubmit": group,
            "PermissionRequest": group,
            "PostToolUse": group,
            "Stop": group,
            "Notification": [["matcher": "permission_prompt|idle_prompt|agent_needs_input|elicitation_dialog", "hooks": [hook]]],
        ]]
    }

    /// Claude Code MCP config passed with --mcp-config.
    public static func claudeMCP() -> [String: Any] {
        ["mcpServers": ["dojo": ["command": "sh", "args": ["-c", shimCommand]]]]
    }

    public static func json(_ object: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    /// The harness command line, the same locally and remotely.
    /// `askFirst` keeps the harness's own approvals: Claude asks for each permission, Codex keeps its
    /// approvals and sandbox. Off by default: a supervised pane runs without prompts.
    public static func harnessWords(kind: HarnessKind, paneName: String, port: Int, runnerModel: String?, askFirst: Bool = false) -> [ShellWord] {
        let prompt = PeerRule.launchPrompt(paneName: paneName)
        switch kind {
        case .claude:
            return [.literal("claude")] + (askFirst ? [] : [.literal("--dangerously-skip-permissions")]) +
                   [.literal("--settings"), .literal(json(claudeSettings(port: port))),
                    .literal("--append-system-prompt"), .literal(prompt),
                    .literal("--mcp-config"), .literal(json(claudeMCP()))]
        case .codex:
            // MCP server and hooks live in ~/.codex/config.toml (written by "dojo install").
            // Owner default: --yolo (no approvals, no sandbox); the hook-trust bypass
            // means the pane's state hooks run without a /hooks confirmation.
            return [.literal("codex")] + (askFirst ? [] : [.literal("--yolo")]) + [.literal("--dangerously-bypass-hook-trust"),
                    .literal("-c"), .literal("developer_instructions=" + Shell.toml(prompt))]
        case .pi:
            // The pane's pi gets its four coding tools whatever the owner's pi settings say
            // (a `defaultTools: []` there would leave it without bash, and so without dojo).
            var words: [ShellWord] = [.literal("pi"), .literal("-e"), .raw(#""$HOME/.dojo/dojo-pi.ts""#),
                                      .literal("--provider"), .literal("runner")]
            if let runnerModel { words += [.literal("--model"), .literal(runnerModel)] }
            // Full-screen layout with the composer at the bottom, whatever the owner's tuiMode setting says;
            // in regular mode pi draws from the top of the pane down and leaves the rest empty.
            return words + [.literal("--tui-mode"), .literal("fullscreen"), .literal("--tools"), .literal(piTools),
                            .literal("--append-system-prompt"), .literal(prompt + " " + piReplyHint)]
        case .runner:
            // Finds or fetches Runner, picks a model that fits this machine and serves it (tools/runner-start.sh).
            return [.literal("/bin/sh"), .raw(#""$HOME/.dojo/runner-start.sh""#)]
        case .shell:
            return [.literal("/bin/sh"), .literal("-c"), .literal("echo ok")]
        }
    }

    /// The plan for a pane. Local panes run in the owner's login shell so PATH matches their terminal.
    /// Remote panes run `ssh -t -R port:127.0.0.1:port host` with the same harness command in the remote login shell.
    /// A Windows host (cmd.exe over OpenSSH) runs the same inner command in MSYS2 bash; see `windowsRemoteCommand`.
    public static func plan(kind: HarnessKind, paneName: String, host: String?, port: Int, token: String,
                            runnerModel: String?, loginShell: String, remoteShell: RemoteShell = .posix,
                            directory: String? = nil, askFirst: Bool = false) -> LaunchPlan {
        let env = ["DOJO_PANE": paneName, "DOJO_PORT": String(port), "DOJO_TOKEN": token]
        let local = host == nil || host!.isEmpty
        let directory = directory?.isEmpty == false ? directory : nil
        if kind == .shell, local {
            // The smoke types a line into this pane and expects it back.
            return LaunchPlan(executable: "/bin/sh", args: ["-c", "read line; echo \"ok $line\""], environment: env, directory: directory)
        }
        let harness = harnessWords(kind: kind, paneName: paneName, port: port, runnerModel: runnerModel, askFirst: askFirst)
        let path: ShellWord = .raw(#"PATH="$HOME/.dojo/bin:$PATH""#)
        guard let host, !local else {
            let line = "exec " + Shell.line([.literal("env"), path] + harness)
            return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", line], environment: env, directory: directory)
        }
        let assignments: [ShellWord] = ["DOJO_PANE", "DOJO_PORT", "DOJO_TOKEN"].map { .literal("\($0)=\(env[$0]!)") }
        let cd = directory.map { "cd " + Shell.homeQuoted($0) + " && " } ?? ""
        let inner = cd + "exec " + Shell.line([.literal("env")] + assignments + [path] + harness)
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

    /// Runs the probe. When the host does not answer it (an unknown host key under BatchMode, a password
    /// prompt, no route), the shell is assumed POSIX and `note` says so, for the pane to show first.
    public static func probeRemoteShell(host: String) async -> (shell: RemoteShell, note: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = probeWords(host: host).dropFirst().compactMap { if case .literal(let s) = $0 { return s } else { return nil } }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (.posix, probeNote(error: "\(error)")) }
        let (output, errors, status): (String, String, Int32) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self), process.terminationStatus))
            }
        }
        if status != 0 { return (.posix, probeNote(error: errors)) }
        return (RemoteShell.detect(probeOutput: output), nil)
    }

    /// The line a pane shows when its host did not answer the shell probe.
    public static func probeNote(error: String) -> String {
        let first = error.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "no answer"
        return "The host did not answer the shell probe (\(first)); assuming a POSIX shell. " +
            "For a Windows host, connect once from a terminal (ssh host) to accept its key, then add the pane again."
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
        let message = "Runner is not answering at \(runnerURL).\\nAdd a Runner pane (the + button): it fetches Runner if needed, picks a model that fits this Mac and serves it.\\nThen close this pane and add pi again.\\n"
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

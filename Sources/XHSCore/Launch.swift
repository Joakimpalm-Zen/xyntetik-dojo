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
    /// Windows OpenSSH with cmd.exe as its shell: the harness runs in MSYS2 bash, at C:\msys64 unless the
    /// host's ssh session names another (`msysBash(probeOutput:)`).
    case windows

    /// The command the app runs over ssh before a remote pane starts.
    /// cmd.exe expands %OS% to Windows_NT; a POSIX shell echoes it as written. cmd.exe also expands
    /// %DOJO_MSYS2_BASH% from the ssh session's environment (sshd's SetEnv, or the user's environment) when
    /// it is set, and leaves it as written when it is not.
    public static let probe = "echo %OS% %DOJO_MSYS2_BASH%"

    public static func detect(probeOutput: String) -> RemoteShell {
        probeOutput.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Windows_NT") ? .windows : .posix
    }

    /// The MSYS2 bash a Windows host names in DOJO_MSYS2_BASH, from the probe's answer; nil when it names
    /// none (cmd.exe left the variable as written) or names one with a character cmd.exe would act on.
    public static func msysBash(probeOutput: String) -> String? {
        let line = probeOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("Windows_NT") else { return nil }
        let path = line.dropFirst("Windows_NT".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.contains("%") else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: #" :\/._-()"#))
        guard path.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return path
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

    /// Claude Code settings passed with --settings: the light theme for the paper panes and bus hooks.
    /// The theme applies locally and over SSH without changing the host's saved preference.
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
        return ["theme": "light", "hooks": [
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
    public static func harnessWords(kind: HarnessKind, paneName: String, port: Int, runnerModel: String?, askFirst: Bool = false,
                                    session: String? = nil) -> [ShellWord] {
        let prompt = PeerRule.launchPrompt(paneName: paneName)
        switch kind {
        case .claude:
            return [.literal("claude")] + (session.map { [.literal("--resume"), .literal($0)] } ?? []) +
                   (askFirst ? [] : [.literal("--dangerously-skip-permissions")]) +
                   [.literal("--settings"), .literal(json(claudeSettings(port: port))),
                    .literal("--append-system-prompt"), .literal(prompt),
                    .literal("--mcp-config"), .literal(json(claudeMCP()))]
        case .codex:
            // MCP server and hooks live in ~/.codex/config.toml (written by "dojo install").
            // Owner default: --yolo (no approvals, no sandbox); the hook-trust bypass
            // means the pane's state hooks run without a /hooks confirmation.
            // `codex resume` does not list --yolo, so a resumed pane uses the long form.
            let start: [ShellWord] = session.map { [.literal("codex"), .literal("resume"), .literal($0)] } ?? [.literal("codex")]
            let bypass = session == nil ? "--yolo" : "--dangerously-bypass-approvals-and-sandbox"
            return start + (askFirst ? [] : [.literal(bypass)]) + [.literal("--dangerously-bypass-hook-trust"),
                    .literal("-c"), .literal("developer_instructions=" + Shell.toml(prompt))]
        case .pi:
            // The pane's pi gets its four coding tools whatever the owner's pi settings say
            // (a `defaultTools: []` there would leave it without bash, and so without dojo).
            var words: [ShellWord] = [.literal("pi"), .literal("-e"), .raw(#""$HOME/.dojo/dojo-pi.ts""#),
                                      .literal("--provider"), .literal("runner")]
            if let runnerModel { words += [.literal("--model"), .literal(runnerModel)] }
            // The app names pi's session from the start: the same flag creates it and finds it again.
            if let session { words += [.literal("--session-id"), .literal(session)] }
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
    /// Remote panes run `ssh -t -R remotePort:127.0.0.1:port host` with the same harness command in the remote
    /// login shell. Each has its own `remotePort`, so closing one leaves the others on the bus.
    /// A Windows host (cmd.exe over OpenSSH) runs the same inner command in MSYS2 bash; see `windowsRemoteCommand`.
    ///
    /// `runnerForward` (D12): a Runner pane on a host also forwards that host's Runner port to this port on
    /// this Mac, on the same ssh connection, so the tunnel lives exactly as long as the pane.
    /// `runnerURL`: the Runner a pi pane uses when it is not the one on its own machine's 8080.
    public static func plan(kind: HarnessKind, paneName: String, host: String?, port: Int, token: String,
                            runnerModel: String?, loginShell: String, remoteShell: RemoteShell = .posix,
                            directory: String? = nil, askFirst: Bool = false, remotePort: Int? = nil,
                            session: String? = nil, runnerForward: Int? = nil, runnerURL: String? = nil,
                            msysBash: String? = nil) -> LaunchPlan {
        let local = host == nil || host!.isEmpty
        // The port the harness calls: on a host, its end of this pane's forward.
        let busPort = local ? port : remotePort ?? port
        var env = ["DOJO_PANE": paneName, "DOJO_PORT": String(busPort), "DOJO_TOKEN": token]
        if let runnerURL { env["DOJO_RUNNER_URL"] = runnerURL }
        if kind == .runner, !local {
            // A Runner pane on a host serves on Dojo's port there, not the host's own 8080, and raises no
            // tray: the pane owns the server, and closing it leaves nothing behind (runner-start.sh).
            env["DOJO_RUNNER_PORT"] = String(remoteRunnerPort)
            env["DOJO_RUNNER_TRAY"] = "off"
        }
        let directory = directory?.isEmpty == false ? directory : nil
        if kind == .shell, local {
            // The smoke types a line into this pane and expects it back.
            return LaunchPlan(executable: "/bin/sh", args: ["-c", "read line; echo \"ok $line\""], environment: env, directory: directory)
        }
        let harness = harnessWords(kind: kind, paneName: paneName, port: busPort, runnerModel: runnerModel, askFirst: askFirst, session: session)
        let path: ShellWord = .raw(#"PATH="$HOME/.dojo/bin:$PATH""#)
        guard let host, !local else {
            let line = "exec " + Shell.line([.literal("env"), path] + harness)
            return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", line], environment: env, directory: directory)
        }
        let assignments: [ShellWord] = ["DOJO_PANE", "DOJO_PORT", "DOJO_TOKEN", "DOJO_RUNNER_URL",
                                        "DOJO_RUNNER_PORT", "DOJO_RUNNER_TRAY"].compactMap { key in
            env[key].map { .literal("\(key)=\($0)") }
        }
        let cd = directory.map { "cd " + Shell.homeQuoted($0) + " && " } ?? ""
        let inner = cd + "exec " + Shell.line([.literal("env")] + assignments + [path] + harness)
        let remote: String
        switch remoteShell {
        case .posix: remote = #"exec "$SHELL" -l -i -c "# + Shell.quote(inner)
        case .windows: remote = windowsRemoteCommand(inner: inner, bash: msysBash)
        }
        let ssh = sshWords(host: host, port: port, remotePort: busPort, remoteCommand: remote,
                           runnerForward: kind == .runner ? runnerForward : nil)
        return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", "exec " + Shell.line(ssh)], environment: env)
    }

    /// MSYS2's bash on a Windows host. The standard MSYS2 install location.
    public static let msysBash = #"C:\msys64\usr\bin\bash.exe"#

    /// The remote command for a Windows host, parsed by cmd.exe and then by bash.exe.
    /// The inner POSIX line travels as base64 so that cmd.exe never sees a quote, a pipe or a percent sign
    /// from it. `^` escapes the characters cmd.exe would otherwise act on, and `\"` is a quote for bash.exe.
    /// MSYS2_PATH_TYPE=inherit keeps the user's Windows PATH (claude, codex, python) in the login shell.
    /// `bash`: the MSYS2 bash the host named (DOJO_MSYS2_BASH), else the standard location; quoted for cmd.exe
    /// when its path has a space.
    public static func windowsRemoteCommand(inner: String, bash: String? = nil) -> String {
        let encoded = Data(inner.utf8).base64EncodedString()
        let path = bash ?? msysBash
        return "set MSYS2_PATH_TYPE=inherit&& " + (path.contains(" ") ? "\"" + path + "\"" : path)
            + #" -lc "eval \"$^(echo "# + encoded + #" ^| base64 -d^)\"""#
    }

    /// The inner command a Windows remote command carries, for tests and troubleshooting.
    public static func windowsInnerCommand(_ remote: String) -> String? {
        guard let start = remote.range(of: "echo "), let end = remote.range(of: " ^|", range: start.upperBound..<remote.endIndex),
              let data = Data(base64Encoded: String(remote[start.upperBound..<end.lowerBound])) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `ssh host 'echo %OS% %DOJO_MSYS2_BASH%'` without a tty, to find out which shell the host runs commands in,
    /// and on Windows which MSYS2 bash its ssh session names.
    public static func probeWords(host: String) -> [ShellWord] {
        [.literal("ssh"), .literal("-o"), .literal("BatchMode=yes"), .literal("-o"), .literal("ConnectTimeout=5"),
         .literal(host), .literal(RemoteShell.probe)]
    }

    /// Runs the probe. When the host does not answer it (an unknown host key under BatchMode, a password
    /// prompt, no route), the shell is assumed POSIX and `note` says so, for the pane to show first.
    public static func probeRemoteShell(host: String) async -> (shell: RemoteShell, bash: String?, note: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = probeWords(host: host).dropFirst().compactMap { if case .literal(let s) = $0 { return s } else { return nil } }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (.posix, nil, probeNote(error: "\(error)")) }
        let (output, errors, status): (String, String, Int32) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (String(decoding: data, as: UTF8.self), String(decoding: errData, as: UTF8.self), process.terminationStatus))
            }
        }
        if status != 0 { return (.posix, nil, probeNote(error: errors)) }
        return (RemoteShell.detect(probeOutput: output), RemoteShell.msysBash(probeOutput: output), nil)
    }

    /// The session a pi pane starts with. Only a local pi that lists the flag gets one: any other starts as it
    /// always has, because a pi that does not know the flag would not start at all.
    public static func piSession(saved: String?, host: String, listed: Bool, newId: @autoclosure () -> String) -> String? {
        host.isEmpty && listed ? saved ?? newId() : nil
    }

    /// Whether a reopened pane lost its conversation: it had none to resume, or it has another now. Only
    /// the coding agents keep one, so a shell or Runner pane never says so.
    public static func startsFresh(kind: HarnessKind, reopened: Bool, saved: String?, session: String?) -> Bool {
        reopened && HarnessKind.pickable.contains(kind) && (saved == nil || session != saved)
    }

    /// Whether a command's output lists `flag`, run in the login shell as a pane is. No answer in `timeout`
    /// seconds is a no, so a slow or hanging profile cannot hold a pane back.
    public static func helpLists(_ flag: String, command: String, loginShell: String, timeout: TimeInterval = 5) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShell)
        process.arguments = ["-l", "-i", "-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        guard (try? process.run()) != nil else { return false }
        return await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            DispatchQueue.global().async {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                answer.give(String(decoding: data, as: UTF8.self).contains(flag))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                process.terminate()
                answer.give(false)
            }
        }
    }

    /// Resumes a continuation with the first answer of two that race.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

        func give(_ answer: Bool) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: answer)
        }
    }

    /// The line a pane shows when its host did not answer the shell probe.
    public static func probeNote(error: String) -> String {
        let first = error.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "no answer"
        return "The host did not answer the shell probe (\(first)); assuming a POSIX shell. " +
            "For a Windows host, connect once from a terminal (ssh host) to accept its key, then add the pane again."
    }

    /// ssh with a reverse tunnel so the shim on the remote host reaches the bus at 127.0.0.1:remotePort there.
    public static func sshWords(host: String, port: Int, remotePort: Int, remoteCommand: String,
                                runnerForward: Int? = nil) -> [ShellWord] {
        // The keepalive: a dropped connection ends the pane within 90 seconds instead of hanging it.
        var words: [ShellWord] = [.literal("ssh"), .literal("-t"), .literal("-R"), .literal("\(remotePort):127.0.0.1:\(port)")]
        // D12: a Runner pane on a host brings that host's Runner to this Mac. ExitOnForwardFailure: a local port
        // someone took since it was picked ends the pane with ssh's own message, not a pane with no tunnel.
        if let runnerForward {
            words += [.literal("-L"), .literal("\(runnerForward):127.0.0.1:\(remoteRunnerPort)"),
                      .literal("-o"), .literal("ExitOnForwardFailure=yes")]
        }
        return words + [.literal("-o"), .literal("ServerAliveInterval=30"), .literal("-o"), .literal("ServerAliveCountMax=3"),
                        .literal(host), .literal(remoteCommand)]
    }

    /// The port Runner serves on, on this Mac.
    public static let runnerPort = 8080

    /// The port a Runner pane on another host serves on there (DOJO_RUNNER_PORT): Dojo's own, so a host's
    /// 8080, which may be another server's, is never taken. A pi pane on that host reaches it at `hostRunnerURL`.
    public static let remoteRunnerPort = 18080
    public static let hostRunnerURL = "http://127.0.0.1:\(remoteRunnerPort)/v1"

    /// Where a remote Runner pane's forward listens on this Mac: a block of its own, clear of Runner's own port
    /// and the bus.
    public static let runnerForwardPorts = 18081...18180

    /// A port for a remote Runner pane's forward: not one another pane holds, and free to bind now.
    public static func runnerForwardPort(taken: Set<Int>, isFree: (Int) -> Bool = Launcher.portIsFree) -> Int? {
        runnerForwardPorts.first { !taken.contains($0) && isFree($0) }
    }

    /// Whether 127.0.0.1:`port` can be bound right now.
    public static func portIsFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// The URL a pi pane on this Mac reaches a Runner at: its own 8080, or a remote Runner pane's forward.
    public static func runnerURL(forward: Int?) -> String {
        forward.map { "http://127.0.0.1:\($0)/v1" } ?? runnerURL
    }

    /// Where a remote pane's forward can listen on its host: the dynamic ports, which nothing claims for good.
    public static let remotePorts = 49152...65535

    /// A port for a new remote pane, none of `taken`. Random, because another Mac's Dojo may use the same host.
    public static func remotePort(taken: Set<Int>) -> Int {
        Set(remotePorts).subtracting(taken).randomElement() ?? remotePorts.lowerBound
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

    /// The environment for a run that must not reach the owner's home: every way a process finds a home, or a
    /// folder in one, points at `home` or is gone. `real` is the owner's, for what an inherited PATH holds of it.
    public static func contained(_ base: [String: String], home: String, real: String) -> [String: String] {
        var env = base.filter { key, _ in !key.hasPrefix("XDG_") && !["ZDOTDIR", "DOJO_RUNNER_HOME"].contains(key) }
        env["HOME"] = home
        // Foundation's own idea of the home, for NSHomeDirectory and FileManager.
        env["CFFIXED_USER_HOME"] = home
        let dojo = real + "/.dojo"
        if let path = env["PATH"] {
            env["PATH"] = path.split(separator: ":").filter { $0 != dojo && !$0.hasPrefix(dojo + "/") }.joined(separator: ":")
        }
        return env
    }

    /// What a local pi pane shows when Runner does not answer.
    public static func runnerOfflinePlan() -> LaunchPlan {
        let message = "Runner is not answering at \(runnerURL).\\nAdd a Runner pane (the + button): it fetches Runner if needed, picks a model that fits this Mac and serves it.\\nThen close this pane and add pi again.\\n"
        return LaunchPlan(executable: "/bin/sh", args: ["-c", "printf '\(message)'"], environment: [:])
    }

    /// What answers on Runner's port: the first model and who serves it.
    public struct Served: Equatable, Sendable {
        public let model: String
        /// The `owned_by` of the model list: `runner` for Xyntetik Runner, `llamacpp` for llama-server, and so on.
        public let ownedBy: String
        public var isRunner: Bool { ownedBy == "runner" }
        /// The server named for the window: Runner, or the other server's own name.
        public var serverName: String {
            switch ownedBy {
            case "runner": return "Runner"
            case "llamacpp": return "llama-server"
            case "": return "a local server (not Runner)"
            default: return "\(ownedBy) (not Runner)"
            }
        }
    }

    /// The first model of a GET /v1/models response and its `owned_by`.
    public static func served(_ data: Data) -> Served? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["data"] as? [[String: Any]],
              let first = models.first(where: { ($0["id"] as? String)?.isEmpty == false }) else { return nil }
        return Served(model: first["id"] as! String, ownedBy: first["owned_by"] as? String ?? "")
    }

    /// The first model id from Runner's GET /v1/models response.
    public static func firstModelID(_ data: Data) -> String? { served(data)?.model }

    /// Asks the server on Runner's port for its models; nil when nothing answers in two seconds.
    public static func fetchServed(at url: String = runnerURL) async -> Served? {
        var request = URLRequest(url: URL(string: url + "/models")!)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return served(data)
    }

    /// The model served on Runner's port, by Runner or anything else there; nil when nothing answers.
    public static func fetchRunnerModel(at url: String = runnerURL) async -> String? { await fetchServed(at: url)?.model }
}

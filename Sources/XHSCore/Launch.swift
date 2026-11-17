import Foundation

/// A word in a shell command line: quoted, or inserted as written (for $HOME expansions).
public enum ShellWord: Equatable, Sendable {
    case literal(String)
    case raw(String)

    public var rendered: String { rendered(anyShell: false) }

    /// `anyShell`: quoted so that fish reads the word as sh does (`Shell.quoteAnyShell`).
    public func rendered(anyShell: Bool) -> String {
        switch self {
        case .literal(let s): return anyShell ? Shell.quoteAnyShell(s) : Shell.quote(s)
        case .raw(let s): return s
        }
    }
}

public enum Shell {    /// A folder as the remote shell should see it: a leading `~` or `~/` is left to the shell to expand,
    /// the rest is quoted; anything else is quoted whole.
    public static func homeQuoted(_ path: String, anyShell: Bool = false) -> String {
        let quoted: (String) -> String = anyShell ? quoteAnyShell : quote
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quoted(String(path.dropFirst(2))) }
        return quoted(path)
    }


    /// POSIX single-quote quoting.
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.unicodeScalars.allSatisfy(plain.contains) {
            return s
        }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")

    /// Quoting that sh, bash, zsh, dash, ksh and fish all read as the same word (D32). POSIX quoting writes an
    /// apostrophe as `'\''`, and quoting that once more puts a backslash inside single quotes, where fish
    /// reads `\'` as an apostrophe and `\\` as one backslash while sh reads both as written. Here nothing but
    /// plain text stands inside single quotes: an apostrophe is written `"'"` and a backslash `\\`, both
    /// outside them, which every one of those shells reads alike. So a line quoted this way can be quoted
    /// again, any number of times, for a chain of shells of which any may be fish.
    ///
    /// A word of plain characters is left as it is, as `quote` leaves it, with two exceptions. One with an
    /// equals sign in it is quoted: zsh takes a bare word that starts with one for a command to look up,
    /// and with MAGIC_EQUAL_SUBST on it expands what follows an equals sign anywhere in a bare word. One
    /// with a percent sign in it is quoted: fish puts its own process id for the bare word `%self` (fish
    /// 4.9.3 did so for that word alone; any word with a percent sign is quoted, whatever another fish does
    /// with a longer one). Of what fish expands in a bare word (command substitution, braces, variables, a
    /// leading tilde, wildcards, `%self`), the percent sign is the only one among the plain characters.
    ///
    /// So `KEY=value` comes out quoted. That is right for an argument, to `env` or to `ssh -o`, which is all
    /// this is used for. It is not for an assignment the shell itself must see in front of a command: a
    /// quoted one is a command name to the shell.
    ///
    /// The price is length where a line is quoted more than once. Measured, for one between plain text: a
    /// backslash is 4 bytes after one quoting, 12 after two and 34 after three, against 1 at every level the
    /// POSIX way; an apostrophe is 5, 17 and 53, against 4, 13 and 40. A remote pane's folder is quoted three
    /// times, so a folder name with thousands of backslashes makes a command the system will not pass.
    public static func quoteAnyShell(_ s: String) -> String {
        if !s.isEmpty, !s.contains("="), !s.contains("%"), s.unicodeScalars.allSatisfy(plain.contains) { return s }
        var out = ""
        var run = String.UnicodeScalarView()
        func endRun() {
            if !run.isEmpty { out += "'" + String(run) + "'" }
            run = String.UnicodeScalarView()
        }
        for scalar in s.unicodeScalars {
            switch scalar {
            case "'": endRun(); out += "\"'\""
            case "\\": endRun(); out += "\\\\"
            default: run.append(scalar)
            }
        }
        endRun()
        return out.isEmpty ? "''" : out
    }

    public static func line(_ words: [ShellWord], anyShell: Bool = false) -> String {
        words.map { $0.rendered(anyShell: anyShell) }.joined(separator: " ")
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

    /// What an agy pane runs agy with: the pane's rows less one as new lines, then agy (its words follow as
    /// the script's arguments). agy draws a new session from its cursor down, so a fresh pane had its composer
    /// near the top; from the last row, agy's first frame stands at the foot and stays there (D38 follow-up,
    /// read off agy in a pty). The rows come from `stty size` in the pane's own shell, here or on a host; with
    /// no terminal, no stty or an answer that is no size, no line is printed and agy starts as before. sh
    /// reads it with nothing but what sh has built in, and stty. No apostrophe and no backslash, which would
    /// cost bytes in the quoting a fish login shell needs (see `reachCheck`).
    ///
    /// It also puts its own pid in DOJO_AGY_PID, which agy keeps, run with exec: Dojo's plugin acts for that
    /// agy alone, which runs its hook and status-line commands as its own children (a probe on 2026-11-17).
    /// An agy the pane's agent runs under it (agy -p) inherits the variable, and has a pid of its own (the
    /// second read of #114).
    public static let agyFootStart = [
        #"DOJO_AGY_PID=$$; export DOJO_AGY_PID"#,
        #"size=$(stty size 2>/dev/null); rows=${size%% *}"#,
        #"case $rows in ""|*[!0-9]*) ;; *) i=1; while [ "$i" -lt "$rows" ]; do echo; i=$((i+1)); done;; esac"#,
        #"exec "$@""#,
    ].joined(separator: "; ")

    /// The variable an agy pane carries its peer rule in, for `dojo hook agy` to inject at SessionStart.
    public static let agyRuleVariable = "DOJO_PEER_RULE"

    /// agy settings passed with --settings, for the session only (agy never saves them): Dojo's own status
    /// line. agy has no hook for a permission ask; its status-line command gets tool_confirmation_pending
    /// while a confirmation dialog shows, and `dojo statusline agy` reports that to the bus. It prints one
    /// plain line like the other panes.
    public static func agySettings() -> [String: Any] {
        ["statusLine": ["type": "command", "command": #"python3 "$HOME/.dojo/dojo-mcp.py" statusline agy"#]]
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
    /// `unrestricted` is the picker's "Skip permission prompts" tick (D21.1): Claude and agy run with
    /// --dangerously-skip-permissions, Codex with no approvals and no sandbox. Off by default, so a pane
    /// keeps the harness's own permission prompts unless the owner ticks it. pi has no permission prompts
    /// to skip (see `Permissions`), so the tick changes nothing there.
    public static func harnessWords(kind: HarnessKind, paneName: String, port: Int, runnerModel: String?, unrestricted: Bool = false,
                                    session: String? = nil) -> [ShellWord] {
        let prompt = PeerRule.launchPrompt(paneName: paneName)
        switch kind {
        case .claude:
            return [.literal("claude")] + (session.map { [.literal("--resume"), .literal($0)] } ?? []) +
                   (unrestricted ? [.literal("--dangerously-skip-permissions")] : []) +
                   [.literal("--settings"), .literal(json(claudeSettings(port: port))),
                    .literal("--append-system-prompt"), .literal(prompt),
                    .literal("--mcp-config"), .literal(json(claudeMCP()))]
        case .codex:
            // MCP server and hooks live in ~/.codex/config.toml (written by "dojo install").
            // Ticked: --yolo, no approvals and no sandbox; `codex resume` does not list --yolo, so a
            // resumed pane uses the long form. The hook-trust bypass is Dojo's own, in both states: the
            // pane's state hooks, which "dojo install" wrote, run without a /hooks confirmation. It lets
            // the model do nothing more.
            let start: [ShellWord] = session.map { [.literal("codex"), .literal("resume"), .literal($0)] } ?? [.literal("codex")]
            let bypass = session == nil ? "--yolo" : "--dangerously-bypass-approvals-and-sandbox"
            return start + (unrestricted ? [.literal(bypass)] : []) + [.literal("--dangerously-bypass-hook-trust"),
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
        case .agy:
            // D38: the Antigravity CLI. Its --settings takes no hooks (agy 1.5.9: "unknown setting") and it has no
            // flag for a system prompt: its hooks and the bus come from Dojo's plugin, which "dojo install" puts
            // in agy's config, and the plugin's SessionStart hook hands agy this pane's rule from the environment
            // (`dojo hook agy`). A resumed conversation fires no SessionStart; it keeps the rule it was given at
            // its start. The tick is agy's own flag, which approves every tool request. --settings carries the
            // pane's status line, which reports a permission dialog (`agySettings`).
            // It starts from the pane's foot (`agyFootStart`): agy draws a new session from its cursor down.
            // DOJO_HARNESS marks an agy pane, and the script's DOJO_AGY_PID the pane's own agy: Dojo's plugin
            // reports only for it, not for an agy run as a tool in another pane, which inherits that pane's
            // DOJO_TOKEN, nor for one run under the pane's own agy, which inherits both.
            return [.literal(agyRuleVariable + "=" + prompt), .literal("DOJO_HARNESS=agy"), .literal("/bin/sh"), .literal("-c"),
                    .literal(agyFootStart),
                    .literal("sh"), .literal("agy")] +
                   (session.map { [.literal("--conversation"), .literal($0)] } ?? []) +
                   (unrestricted ? [.literal("--dangerously-skip-permissions")] : []) +
                   [.literal("--settings"), .literal(json(agySettings()))]
        case .runner:
            // Finds or fetches Runner, picks a model that fits this machine and serves it (tools/runner-start.sh).
            return [.literal("/bin/sh"), .raw(#""$HOME/.dojo/runner-start.sh""#)]
        case .shell:
            return [.literal("/bin/sh"), .literal("-c"), .literal("echo ok")]
        }
    }

    /// The plan for a pane. Local panes run in the owner's login shell so PATH matches their terminal.
    /// Remote panes run `ssh -t -R remotePort:127.0.0.1:port host` with the same harness command in the remote
    /// login shell. For a POSIX host the whole command is quoted with `Shell.quoteAnyShell` at each of its
    /// three levels (this Mac's login shell, the host's login shell that sshd hands the command, and that
    /// login shell started again with `-l -i`), since any of the three may be fish (D32). What each level
    /// runs is what it always ran: the login shell changes folder and starts the harness itself. Each has its own `remotePort`, so closing one leaves the others on the bus.
    /// A Windows host (cmd.exe over OpenSSH) runs the same inner command in MSYS2 bash; see `windowsRemoteCommand`.
    ///
    /// `runnerForward` (D12): a Runner pane on a host also forwards that host's Runner port to this port on
    /// this Mac, on the same ssh connection, so the tunnel lives exactly as long as the pane.
    /// `runnerURL`: the Runner a pi pane uses when it is not the one on its own machine's 8080.
    public static func plan(kind: HarnessKind, paneName: String, host: String?, port: Int, token: String,
                            runnerModel: String?, loginShell: String, remoteShell: RemoteShell = .posix,
                            directory: String? = nil, unrestricted: Bool = false, remotePort: Int? = nil,
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
        let harness = harnessWords(kind: kind, paneName: paneName, port: busPort, runnerModel: runnerModel, unrestricted: unrestricted, session: session)
        let path: ShellWord = .raw(#"PATH="$HOME/.dojo/bin:$PATH""#)
        guard let host, !local else {
            let line = "exec " + Shell.line([.literal("env"), path] + harness)
            return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", line], environment: env, directory: directory)
        }
        let assignments: [ShellWord] = ["DOJO_PANE", "DOJO_PORT", "DOJO_TOKEN", "DOJO_RUNNER_URL",
                                        "DOJO_RUNNER_PORT", "DOJO_RUNNER_TRAY"].compactMap { key in
            env[key].map { .literal("\(key)=\($0)") }
        }
        // A Windows host's command is built as before: cmd.exe and MSYS2 bash read it, never fish.
        let anyShell = remoteShell == .posix
        let cd = directory.map { "cd " + Shell.homeQuoted($0, anyShell: anyShell) + " && " } ?? ""
        // D35.2: a pane that reports hooks first asks the bus through its tunnel whether it knows this pane,
        // with the shim that is on the host for the hooks. One more command in the line the host's login
        // shell reads, run by sh so that every login shell reads it alike: by its full path on a POSIX
        // host, where a login profile can leave /bin off the PATH.
        let reach = reportsHooks.contains(kind)
            ? Shell.line([.literal("env")] + assignments + [path, .literal(remoteShell == .posix ? "/bin/sh" : "sh"), .literal("-c"),
                          .literal(reachCheck)], anyShell: anyShell) + " && "
            : ""
        let inner = cd + reach + "exec " + Shell.line([.literal("env")] + assignments + [path] + harness, anyShell: anyShell)
        let remote: String
        switch remoteShell {
        case .posix: remote = #"exec "$SHELL" -l -i -c "# + Shell.quoteAnyShell(inner)
        case .windows: remote = windowsRemoteCommand(inner: inner, bash: msysBash)
        }
        let ssh = sshWords(host: host, port: port, remotePort: busPort, remoteCommand: remote,
                           runnerForward: kind == .runner ? runnerForward : nil)
        return LaunchPlan(executable: loginShell, args: ["-l", "-i", "-c", "exec " + Shell.line(ssh, anyShell: anyShell)], environment: env)
    }

    /// The harnesses that report their state to the bus by hooks, and so need the way to it.
    public static let reportsHooks: Set<HarnessKind> = [.claude, .codex, .pi, .agy]

    /// D35.2: what a remote pane runs on its host before its harness, with the pane's own DOJO_PORT and
    /// DOJO_TOKEN. Without its way to the bus a harness starts with no hooks, so the bus never learns of a
    /// prompt there. ssh only warns when it cannot make the forward, and a forward ssh did make can still
    /// lead elsewhere: to another program that holds the port on the address the hooks call, or to another
    /// Mac's bus. So the pane asks, with the shim that is on the host for the hooks: `dojo panes`, which the
    /// bus answers by the caller's token and in which the shim marks the caller's own pane.
    ///
    /// The harness starts only on an answer that shows a bus that knows this pane: the shim succeeds, and
    /// one of its lines has the exact shape it gives the caller's own pane: a star, then five words and no
    /// more before "queued=", with a name that is one (the shim writes None for a pane without), a kind the
    /// bus gives and, in the state's place, a state the bus gives. A state word
    /// anywhere else in a line counts for nothing, and lines of another shape are passed over, starred or
    /// not, so a line a host's Python prints when it starts hides nothing. The pane's name is not used, so
    /// a pane renamed while it starts is known all the same. Every other answer from a shim that ran ends
    /// the pane: the bus not reachable, a refusal, a page or a wrong object from a program that is no bus,
    /// a crash of the shim's own.
    ///
    /// Three hosts start as before, each known by its own sign and none by "anything else", and never by
    /// words found somewhere in what the shim printed: no shim on the host (`command -v` fails); a shim
    /// from before the call (status 2 and its usage line first); a shim whose Python is gone (status 127 or
    /// 126, the shell's own for a command that is not there or cannot be run, with no word of the shim's
    /// own and no traceback).
    /// Such a host has no hooks with or without this.
    ///
    /// The pane's line is fixed words and, for a refusal, the status number. What the shim said is never
    /// shown: a program on the port can answer with the request's headers, and the token is one of them.
    ///
    /// sh reads it, on a POSIX host and under MSYS2, with nothing but what sh has built in. It has no
    /// apostrophe and no backslash: each would cost tens of bytes in the quoting a fish login shell needs.
    public static let reachCheck = [
        #"command -v dojo >/dev/null 2>&1 || exit 0"#,
        #"all=$(dojo panes 2>&1); code=$?"#,
        #"nl=$(echo; echo x); nl=${nl%x}; rest=$all; said=; known="#,
        // Line by line. The answer is any line of the exact shape the shim gives the caller's own pane: a
        // star, a name, a kind, a host and a state, five words and no more, then "queued=". Each is read by
        // its place: the name is one (the shim writes None for none), the kind is one the bus gives
        // (HarnessKind), the state is one the bus gives (PaneState).
        #"while :; do line=${rest%%"$nl"*}; "#
            + #"case $line in "* "*" queued="*) cells=${line%%" queued="*}; n=0; word=; name=; kind=; "#
            + #"while :; do cells=${cells#"${cells%%[! ]*}"}; case $cells in "") break;; esac; word=${cells%%" "*}; n=$((n+1)); "#
            + #"case $n in 2) name=$word;; 3) kind=$word;; esac; case $cells in *" "*) cells=${cells#*" "};; *) break;; esac; done; "#
            + #"case $n in 5) case $word in starting|running|idle|prompt|exited) "#
            + #"case $kind in claude|codex|pi|agy|runner|shell) "#
            + #"case $name in None) ;; *) known=yes;; esac;; esac;; esac;; esac;; "#
            // the shim's own words, for the reason the pane gives
            + #""dojo: "*) case $said in "") said=$line;; esac;; esac; "#
            + #"case $rest in *"$nl"*) rest=${rest#*"$nl"};; *) break;; esac; done"#,
        #"case $code$known in 0yes) exit 0;; esac"#,
        // No Python: the shell's own status for a command that is not there (127) or that cannot be run
        // (126: a wrapper whose interpreter was removed), and not a word from the shim.
        // A shim from before the call: its usage line first, with its status for that.
        #"case $code in 126|127) case "$nl$all" in *"${nl}dojo:"*|*Traceback*) ;; *) exit 0;; esac;; "#
            + #"2) case $all in "usage: "*) exit 0;; esac;; esac"#,
        #"why="the answer was not from a bus that knows this pane""#,
        #"case $said in "dojo: bus not reachable"*) why="bus not reachable";; "#
            + #""dojo: bus refused ("*) n=${said#"dojo: bus refused ("}; n=${n%%")"*}; "#
            + #"case $n in ""|*[!0-9]*) why="bus refused";; *) why="bus refused ($n)";; esac;; esac"#,
        #"echo "Dojo: the bus could not be reached through the tunnel of this pane, so the pane does not start: $why." >&2"#,
        "exit 1",
    ].joined(separator: "; ")

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
    /// seconds is a no, so a slow or hanging profile cannot hold a pane back, and the shell is ended then
    /// with all it started.
    public static func helpLists(_ flag: String, command: String, loginShell: String, timeout: TimeInterval = 5) async -> Bool {
        guard let child = Detached(loginShell, ["-l", "-i", "-c", command]) else { return false }
        return await withCheckedContinuation { continuation in
            let answer = Once(continuation)
            DispatchQueue.global().async {
                let data = child.output.readDataToEndOfFile()
                child.outputEnded()
                answer.give(String(decoding: data, as: UTF8.self).contains(flag))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                child.stop()
                answer.give(false)
            }
        }
    }

    /// A program started in a session of its own, so that it has no controlling terminal: stdin /dev/null,
    /// stdout a pipe, stderr /dev/null or a file (`errors`), nothing else of this process's files, and this
    /// process's environment unless it is given one. D38: Foundation's Process puts its child
    /// in a process group of its own; where Dojo has a controlling terminal (started from a terminal, as
    /// `make smoke` in an agy pane, whose shell tool runs commands on one), that group is a background one,
    /// and an interactive login shell there is stopped by SIGTTIN until the time runs out. A pane's harness
    /// never was: it runs in the pane's own terminal, in a session of its own.
    ///
    /// The program leads that session, so the session's id is its pid, and whatever it starts is in it, in
    /// the program's group or, from an interactive shell, in a group of the job's own. A thread of its own
    /// waits for the program to end without reaping it (the second read of #114): until it is reaped, under
    /// the lock `stop()` takes, its pid stays its own and no signal can reach another program that got the
    /// number. It is reaped once its output has ended too, or `stop()` was called: while a program it started
    /// still holds the output open, it is kept, so that `stop()` can end that program as well.
    final class Detached: @unchecked Sendable {
        let pid: pid_t
        let output: FileHandle
        private let lock = NSLock()
        private var exited = false, ended = false, stopped = false, reaped = false
        private var code: Int32 = 0
        private let gone = DispatchSemaphore(value: 0)
        /// For a test: called with the pid once the program has ended, before it is reaped.
        private let onExit: (@Sendable (pid_t) -> Void)?

        init?(_ executable: String, _ arguments: [String], environment: [String: String]? = nil, errors: String? = nil,
              qos: qos_class_t = QOS_CLASS_DEFAULT, onExit: (@Sendable (pid_t) -> Void)? = nil) {
            self.onExit = onExit
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { return nil }
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&actions)
            posix_spawnattr_init(&attributes)
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
            posix_spawn_file_actions_addopen(&actions, 2, errors ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
            posix_spawnattr_set_qos_class_np(&attributes, qos)
            let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
            // this process's environment, as Process gives its child
            let envp: [UnsafeMutablePointer<CChar>?] = (environment ?? ProcessInfo.processInfo.environment)
                .map { strdup($0.key + "=" + $0.value) } + [nil]
            defer { (argv + envp).forEach { free($0) } }
            var pid: pid_t = 0
            let started = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            close(fds[1])
            guard started == 0 else {
                close(fds[0])
                return nil
            }
            self.pid = pid
            output = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
            Thread.detachNewThread { [self] in watch() }
        }

        /// Waits for the program to end, leaving it a zombie, whose pid no other program can get.
        private func watch() {
            var info = siginfo_t()
            while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
            onExit?(pid)
            lock.lock()
            exited = true
            reapWhenDone()
            lock.unlock()
        }

        /// Its output has ended: no program it started holds it any more.
        func outputEnded() {
            lock.lock()
            ended = true
            reapWhenDone()
            lock.unlock()
        }

        /// Ends the program and every one in its session with SIGKILL, unless it has been reaped. An
        /// interactive shell ignores SIGTERM, and what is asked here keeps nothing that needs a clean end. A
        /// program that left the session (a daemon of the profile's) is not reached; if it holds the output,
        /// only the thread reading it waits on. The program's own pid and group are its own until it is
        /// reaped; another member's pid is free once that member ends, so between reading the session and the
        /// signal there is the one kernel call in which it could be taken.
        func stop() {
            lock.lock()
            if !reaped {
                kill(-pid, SIGKILL)
                // twice: one that was being started as the first round ran is ended in the second
                for _ in 0..<2 { for member in Self.session(pid) where member != pid { kill(member, SIGKILL) } }
            }
            stopped = true
            reapWhenDone()
            lock.unlock()
        }

        /// The processes in the session `sid`: every process, kept where getsid says so. macOS's own filter
        /// for a session (KERN_PROC_SESSION, `pgrep -s`) found none of a shell's jobs on 2026-11-17.
        static func session(_ sid: pid_t) -> [pid_t] {
            processes().filter { $0 > 0 && getsid($0) == sid }
        }

        /// Every process's pid (sysctl KERN_PROC_ALL), in two calls: the table's size, then its rows, with room
        /// for more. A table that grew past that room in between gives ENOMEM, and is read again with the
        /// size it has then (the re-read of #114); a few times at most. `read` is sysctl's, or a test's.
        static func processes(read: (UnsafeMutableRawPointer?, inout Int) -> Int32 = { buffer, size in
            var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
            return sysctl(&name, 3, buffer, &size, nil, 0)
        }) -> [pid_t] {
            let stride = MemoryLayout<kinfo_proc>.stride
            for _ in 0..<4 {
                var size = 0
                guard read(nil, &size) == 0, size > 0 else { return [] }
                var found = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
                size = found.count * stride
                let got = found.withUnsafeMutableBytes { read($0.baseAddress, &size) }
                if got == 0 { return found.prefix(size / stride).map(\.kp_proc.p_pid) }
                guard errno == ENOMEM else { return [] }
            }
            return []
        }

        /// Under the lock: reaps the program once it has ended, and its output has too or it was stopped.
        private func reapWhenDone() {
            guard exited, ended || stopped, !reaped else { return }
            var status: Int32 = 0
            waitpid(pid, &status, 0)  // it has ended: this does not wait
            // the exit code, or 128 and the signal that ended it, as a shell says
            code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + status & 0x7f
            reaped = true
            gone.signal()
        }

        /// Waits until the program has been reaped (its output has ended, or it was stopped) and gives its exit
        /// code.
        func exitCode() -> Int32 {
            gone.wait()
            gone.signal()
            lock.lock()
            defer { lock.unlock() }
            return code
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
    /// The listener is asked for with no address named, as it always was: a host whose sshd permits listening
    /// on `localhost` only refuses 127.0.0.1 by name. ssh then asks for the loopback listeners of both
    /// families and is content when either binds, so ssh's silence does not say the tunnel is there. The
    /// pane's own check does (`reachCheck`, D35.2).
    public static func sshWords(host: String, port: Int, remotePort: Int, remoteCommand: String,
                                runnerForward: Int? = nil) -> [ShellWord] {
        // The keepalive: a dropped connection ends the pane within 90 seconds instead of hanging it.
        var words: [ShellWord] = [.literal("ssh"), .literal("-t"), .literal("-R"), .literal("\(remotePort):127.0.0.1:\(port)")]
        // D12: a Runner pane on a host brings that host's Runner to this Mac. ExitOnForwardFailure: a local port
        // someone took since it was picked ends the pane with ssh's own message, not a pane with no tunnel.
        // The option is for that forward alone. It is not how an agent pane learns that its tunnel failed
        // (`reachCheck` is): it ends the pane on any forward that fails, the user's own in ~/.ssh/config too,
        // and a second pane on a host alias with a LocalForward would never start.
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

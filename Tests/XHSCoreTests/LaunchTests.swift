import Foundation
import Testing
@testable import XHSCore

@Suite struct LaunchTests {
    let home = "/home/tester"

    @Test func shellQuoting() {
        #expect(Shell.quote("plain-word_1.2") == "plain-word_1.2")
        #expect(Shell.quote("") == "''")
        #expect(Shell.quote("it's") == #"'it'\''s'"#)
        let tricky = #"a 'b' "c" $HOME `x` \ ; & | * ? [ ] ( ) < > ~ !"#
        #expect(shellArgs(Shell.quote(tricky)) == [tricky])
    }

    @Test func tomlStrings() {
        #expect(Shell.toml(#"say "hi" \ now"#) == #""say \"hi\" \\ now""#)
        #expect(Shell.toml("a\nb") == #""a\nb""#)
    }

    @Test func localClaudeRunsInLoginShellWithHooksAndShim() throws {
        let plan = Launcher.plan(kind: .claude, paneName: "claude-1", host: nil, port: 7788, token: "tok",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        #expect(plan.executable == "/bin/zsh")
        #expect(Array(plan.args.prefix(3)) == ["-l", "-i", "-c"])
        #expect(plan.environment == ["XHS_PANE": "claude-1", "XHS_PORT": "7788", "XHS_TOKEN": "tok"])
        let argv = shellArgs(plan.args[3], home: home)
        #expect(argv.prefix(4) == ["env", "PATH=/home/tester/.xhs/bin:/usr/bin:/bin", "claude",
                                   "--dangerously-skip-permissions"])
        let settings = try #require(argv.firstIndex(of: "--settings"))
        let parsed = try JSONSerialization.jsonObject(with: Data(argv[settings + 1].utf8)) as! NSDictionary
        #expect(parsed == Launcher.claudeSettings(port: 7788) as NSDictionary)
        let mcp = try #require(argv.firstIndex(of: "--mcp-config"))
        #expect(mcp == argv.count - 2)
        let server = try JSONSerialization.jsonObject(with: Data(argv[mcp + 1].utf8)) as! NSDictionary
        #expect(server == Launcher.claudeMCP() as NSDictionary)
        let prompt = try #require(argv.firstIndex(of: "--append-system-prompt"))
        #expect(argv[prompt + 1] == PeerRule.launchPrompt(paneName: "claude-1"))
    }

    @Test func remotePaneTunnelsTheBusOverSSH() throws {
        let plan = Launcher.plan(kind: .codex, paneName: "codex-2", host: "user@box", port: 7788, token: "tok",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        let ssh = shellArgs(plan.args[3], home: home)
        #expect(Array(ssh.prefix(5)) == ["ssh", "-t", "-R", "7788:127.0.0.1:7788", "user@box"])
        #expect(ssh.count == 6)
        // On the remote host: the login shell, then env with the pane's variables, then the harness.
        let remote = shellArgs(ssh[5], home: "/remote/home")
        #expect(Array(remote.prefix(4)) == ["/bin/remote-shell", "-l", "-i", "-c"])
        let harness = shellArgs(remote[4], home: "/remote/home")
        #expect(Array(harness.prefix(6)) == ["env", "XHS_PANE=codex-2", "XHS_PORT=7788", "XHS_TOKEN=tok",
                                             "PATH=/remote/home/.xhs/bin:/usr/bin:/bin", "codex"])
        #expect(Array(harness[6...8]) == ["--yolo", "--dangerously-bypass-hook-trust", "-c"])
        #expect(harness[9] == "developer_instructions=" + Shell.toml(PeerRule.launchPrompt(paneName: "codex-2")))
    }

    @Test func remoteUsesTheConfiguredPort() {
        let plan = Launcher.plan(kind: .pi, paneName: "pi-1", host: "box", port: 9001, token: "t",
                                 runnerModel: nil, loginShell: "/bin/bash")
        #expect(shellArgs(plan.args[3]).prefix(4) == ["ssh", "-t", "-R", "9001:127.0.0.1:9001"])
    }

    @Test func piUsesRunnerProviderAndTheFirstModel() throws {
        let local = Launcher.plan(kind: .pi, paneName: "pi-1", host: nil, port: 7788, token: "t",
                                  runnerModel: "qwen3-8b", loginShell: "/bin/zsh")
        let argv = shellArgs(local.args[3], home: home)
        #expect(Array(argv[2...7]) == ["pi", "-e", "/home/tester/.xhs/xhs-pi.ts", "--provider", "runner", "--model"])
        #expect(argv[8] == "qwen3-8b")
        // Tools are passed explicitly: the owner's pi settings may turn them all off, and xhs needs bash.
        let tools = try #require(argv.firstIndex(of: "--tools"))
        #expect(argv[tools + 1] == "read,bash,edit,write")
        // Full-screen layout, whatever the owner's tuiMode setting says: the composer sits at the bottom.
        let mode = try #require(argv.firstIndex(of: "--tui-mode"))
        #expect(argv[mode + 1] == "fullscreen")
        let remote = Launcher.harnessWords(kind: .pi, paneName: "pi-1", port: 7788, runnerModel: nil)
        #expect(!remote.contains(.literal("--model")))
        #expect(remote.contains(.literal("--tools")))
    }

    @Test func windowsHostRunsTheSameInnerCommandInMsysBash() throws {
        let posix = Launcher.plan(kind: .claude, paneName: "claude-3", host: "me@box", port: 7788, token: "tok",
                                  runnerModel: nil, loginShell: "/bin/zsh")
        let windows = Launcher.plan(kind: .claude, paneName: "claude-3", host: "me@box", port: 7788, token: "tok",
                                    runnerModel: nil, loginShell: "/bin/zsh", remoteShell: .windows)
        let ssh = shellArgs(windows.args[3], home: home)
        #expect(Array(ssh.prefix(5)) == ["ssh", "-t", "-R", "7788:127.0.0.1:7788", "me@box"])
        #expect(ssh.count == 6)
        let remote = ssh[5]
        let head = #"set MSYS2_PATH_TYPE=inherit&& C:\msys64\usr\bin\bash.exe -lc "eval \"$^(echo "#
        let tail = #" ^| base64 -d^)\"""#
        #expect(remote.hasPrefix(head))
        #expect(remote.hasSuffix(tail))
        // cmd.exe sees no quote, pipe, percent or parenthesis from the harness line: it travels as base64.
        let payload = remote.dropFirst(head.count).dropLast(tail.count)
        #expect(!payload.isEmpty)
        #expect(payload.allSatisfy { $0.isLetter || $0.isNumber || "+/=".contains($0) })
        // bash.exe then runs exactly the line a POSIX host's login shell gets.
        let posixInner = shellArgs(shellArgs(posix.args[3], home: home)[5], home: "/remote/home")[4]
        #expect(Launcher.windowsInnerCommand(remote) == posixInner)
        let harness = shellArgs(try #require(Launcher.windowsInnerCommand(remote)), home: "/c/Users/me")
        #expect(Array(harness.prefix(6)) == ["env", "XHS_PANE=claude-3", "XHS_PORT=7788", "XHS_TOKEN=tok",
                                             "PATH=/c/Users/me/.xhs/bin:/usr/bin:/bin", "claude"])
    }

    @Test func remoteShellProbe() {
        #expect(RemoteShell.detect(probeOutput: "Windows_NT \r\n") == .windows)
        #expect(RemoteShell.detect(probeOutput: "%OS%\n") == .posix)
        #expect(RemoteShell.detect(probeOutput: "") == .posix)
        #expect(shellArgs(Shell.line(Launcher.probeWords(host: "me@box")))
                == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "me@box", "echo %OS%"])
    }

    @Test func remoteSmokeShellGoesOverSSH() {
        let plan = Launcher.plan(kind: .shell, paneName: "shell-1", host: "box", port: 7799, token: "t",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        #expect(plan.executable == "/bin/zsh")
        let ssh = shellArgs(plan.args[3], home: home)
        #expect(Array(ssh.prefix(2)) == ["ssh", "-t"])
        #expect(shellArgs(shellArgs(ssh[5], home: "/remote/home")[4], home: "/remote/home").suffix(3) == ["/bin/sh", "-c", "echo ok"])
    }

    @Test func panesStartInTheChosenFolder() {
        let local = Launcher.plan(kind: .claude, paneName: "claude-1", host: nil, port: 7788, token: "t",
                                  runnerModel: nil, loginShell: "/bin/zsh", directory: "/home/tester/repo")
        #expect(local.directory == "/home/tester/repo")
        #expect(Launcher.plan(kind: .claude, paneName: "c", host: nil, port: 1, token: "t", runnerModel: nil,
                              loginShell: "/bin/zsh", directory: "").directory == nil)
        let remote = Launcher.plan(kind: .codex, paneName: "codex-1", host: "box", port: 7788, token: "t",
                                   runnerModel: nil, loginShell: "/bin/zsh", directory: "/srv/it's here")
        #expect(remote.directory == nil)
        let inner = shellArgs(shellArgs(remote.args[3], home: home)[5], home: "/remote/home")[4]
        #expect(inner.hasPrefix("cd '/srv/it'\\''s here' && exec env "))
        let windows = Launcher.plan(kind: .codex, paneName: "codex-1", host: "me@box", port: 7788, token: "t",
                                    runnerModel: nil, loginShell: "/bin/zsh", remoteShell: .windows, directory: #"C:\Users\zen\repo"#)
        #expect(Launcher.windowsInnerCommand(shellArgs(windows.args[3], home: home)[5])?.hasPrefix(#"cd 'C:\Users\zen\repo' && exec env "#) == true)
    }

    @Test func recentHostsRememberTheLatestFirst() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xhs-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(RecentHosts.load(file) == [])
        #expect(RecentHosts.remember("me@box", in: file) == ["me@box"])
        #expect(RecentHosts.remember("lab", in: file) == ["lab", "me@box"])
        #expect(RecentHosts.remember("me@box", in: file) == ["me@box", "lab"])
        #expect(RecentHosts.load(file) == ["me@box", "lab"])
        for i in 0..<20 { RecentHosts.remember("h\(i)", in: file) }
        #expect(RecentHosts.load(file).count == RecentHosts.limit)
        try "  \n-bad\nok-host\n\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(RecentHosts.load(file) == ["ok-host"])
        RecentHosts.remember("/Users/me/repo", in: file, valid: RecentHosts.isFolder)
        #expect(RecentHosts.load(file, valid: RecentHosts.isFolder) == ["/Users/me/repo", "-bad", "ok-host"])
    }

    @Test func paneEnvironmentDropsWhatAClaudeSessionHandsDown() {
        let base = ["PATH": "/usr/bin", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_SESSION_ID": "s",
                    "CLAUDE_PID": "7", "LANG": "sv_SE.UTF-8", "HOME": "/home/tester"]
        let env = Launcher.paneEnvironment(from: base, adding: ["XHS_TOKEN": "tok"])
        #expect(env.keys.filter { $0.hasPrefix("CLAUDE") }.isEmpty)
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["LANG"] == "sv_SE.UTF-8")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["XHS_TOKEN"] == "tok")
        #expect(Launcher.paneEnvironment(from: [:], adding: [:])["LANG"] == "en_US.UTF-8")
    }

    @Test func smokeShellPlan() {
        let plan = Launcher.plan(kind: .shell, paneName: "shell-1", host: nil, port: 7788, token: "t",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        #expect(plan.executable == "/bin/sh")
        #expect(plan.args == ["-c", "read line; echo \"ok $line\""])
    }

    @Test func runnerModelsResponse() {
        let data = Data(#"{"object":"list","data":[{"id":"gemma-4-12b","object":"model"},{"id":"other"}]}"#.utf8)
        #expect(Launcher.firstModelID(data) == "gemma-4-12b")
        #expect(Launcher.firstModelID(Data(#"{"data":[]}"#.utf8)) == nil)
        #expect(Launcher.firstModelID(Data("nope".utf8)) == nil)
    }
}

@Suite struct SnippetTests {
    func snippet(_ name: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent("tools/snippets/\(name)"), encoding: .utf8)
    }

    @Test func claudeSnippetsMatchWhatTheAppPasses() throws {
        let settings = try JSONSerialization.jsonObject(with: Data(try snippet("claude-settings.json").utf8)) as! NSDictionary
        #expect(settings == Launcher.claudeSettings(port: Launcher.defaultPort) as NSDictionary)
        let mcp = try JSONSerialization.jsonObject(with: Data(try snippet("claude-mcp.json").utf8)) as! NSDictionary
        #expect(mcp == Launcher.claudeMCP() as NSDictionary)
    }

    @Test func instructionSnippetsCarryThePeerRule() throws {
        for name in ["CLAUDE.md-snippet.md", "codex-AGENTS.md-snippet.md", "pi-APPEND_SYSTEM.md"] {
            #expect(try snippet(name).contains(PeerRule.text), "\(name)")
        }
    }

    @Test func noEmDashesInShippedText() throws {
        #expect(!PeerRule.text.contains("\u{2014}"))
        for name in ["CLAUDE.md-snippet.md", "codex-AGENTS.md-snippet.md", "pi-APPEND_SYSTEM.md"] {
            #expect(try !snippet(name).contains("\u{2014}"))
        }
    }

    @Test func aRunnerPaneRunsTheStartScript() {
        let line = Shell.line(Launcher.harnessWords(kind: .runner, paneName: "runner-1", port: 7788, runnerModel: nil))
        #expect(line == "/bin/sh \"$HOME/.xhs/runner-start.sh\"")
        #expect(PaneNames.next(for: .runner, taken: []) == "runner-1")
    }

    @Test func theFitsFileParses() {
        let text = "bolt\tnvidia/Bolt-4GB:Nemotron-Bolt-Q4_K_M\t-c 16384 --kv q8 --mlock\t2.97\nbad line\nq4\tb/Q-GGUF:Q_Q4_K_M\t-c 16384 --mlock\t2.40\n"
        let fits = RunnerFit.parse(text)
        #expect(fits.map(\.id) == ["bolt", "q4"])
        #expect(fits[0].spelling == "nvidia/Bolt-4GB:Nemotron-Bolt-Q4_K_M")
        #expect(fits[0].flags == "-c 16384 --kv q8 --mlock")
        #expect(fits[0].stem == "Nemotron-Bolt-Q4_K_M")
        #expect(RunnerFit.parse("").isEmpty)
    }
}

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

    @Test func piUsesRunnerProviderAndTheFirstModel() {
        let local = Launcher.plan(kind: .pi, paneName: "pi-1", host: nil, port: 7788, token: "t",
                                  runnerModel: "qwen3-8b", loginShell: "/bin/zsh")
        let argv = shellArgs(local.args[3], home: home)
        #expect(Array(argv[2...7]) == ["pi", "-e", "/home/tester/.xhs/xhs-pi.ts", "--provider", "runner", "--model"])
        #expect(argv[8] == "qwen3-8b")
        let remote = Launcher.harnessWords(kind: .pi, paneName: "pi-1", port: 7788, runnerModel: nil)
        #expect(!remote.contains(.literal("--model")))
    }

    @Test func windowsHostRunsTheSameInnerCommandInMsysBash() throws {
        let posix = Launcher.plan(kind: .claude, paneName: "claude-3", host: "zen@box", port: 7788, token: "tok",
                                  runnerModel: nil, loginShell: "/bin/zsh")
        let windows = Launcher.plan(kind: .claude, paneName: "claude-3", host: "zen@box", port: 7788, token: "tok",
                                    runnerModel: nil, loginShell: "/bin/zsh", remoteShell: .windows)
        let ssh = shellArgs(windows.args[3], home: home)
        #expect(Array(ssh.prefix(5)) == ["ssh", "-t", "-R", "7788:127.0.0.1:7788", "zen@box"])
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
        let harness = shellArgs(try #require(Launcher.windowsInnerCommand(remote)), home: "/c/Users/zen")
        #expect(Array(harness.prefix(6)) == ["env", "XHS_PANE=claude-3", "XHS_PORT=7788", "XHS_TOKEN=tok",
                                             "PATH=/c/Users/zen/.xhs/bin:/usr/bin:/bin", "claude"])
    }

    @Test func remoteShellProbe() {
        #expect(RemoteShell.detect(probeOutput: "Windows_NT \r\n") == .windows)
        #expect(RemoteShell.detect(probeOutput: "%OS%\n") == .posix)
        #expect(RemoteShell.detect(probeOutput: "") == .posix)
        #expect(shellArgs(Shell.line(Launcher.probeWords(host: "zen@box")))
                == ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "zen@box", "echo %OS%"])
    }

    @Test func remoteSmokeShellGoesOverSSH() {
        let plan = Launcher.plan(kind: .shell, paneName: "shell-1", host: "box", port: 7799, token: "t",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        #expect(plan.executable == "/bin/zsh")
        let ssh = shellArgs(plan.args[3], home: home)
        #expect(Array(ssh.prefix(2)) == ["ssh", "-t"])
        #expect(shellArgs(shellArgs(ssh[5], home: "/remote/home")[4], home: "/remote/home").suffix(3) == ["/bin/sh", "-c", "echo ok"])
    }

    @Test func recentHostsRememberTheLatestFirst() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xhs-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(RecentHosts.load(file) == [])
        #expect(RecentHosts.remember("zen@box", in: file) == ["zen@box"])
        #expect(RecentHosts.remember("lab", in: file) == ["lab", "zen@box"])
        #expect(RecentHosts.remember("zen@box", in: file) == ["zen@box", "lab"])
        #expect(RecentHosts.load(file) == ["zen@box", "lab"])
        for i in 0..<20 { RecentHosts.remember("h\(i)", in: file) }
        #expect(RecentHosts.load(file).count == RecentHosts.limit)
        try "  \n-bad\nok-host\n\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(RecentHosts.load(file) == ["ok-host"])
    }

    @Test func smokeShellPlan() {
        let plan = Launcher.plan(kind: .shell, paneName: "shell-1", host: nil, port: 7788, token: "t",
                                 runnerModel: nil, loginShell: "/bin/zsh")
        #expect(plan.executable == "/bin/sh")
        #expect(plan.args == ["-c", "echo ok"])
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
}

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
        #expect(argv.prefix(3) == ["env", "PATH=/home/tester/.xhs/bin:/usr/bin:/bin", "claude"])
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
        #expect(harness[6] == "-c")
        #expect(harness[7] == "developer_instructions=" + Shell.toml(PeerRule.launchPrompt(paneName: "codex-2")))
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

import Foundation
import Testing
@testable import XHSCore

/// Each remote pane reaches the bus by its own forward, so closing one leaves the others connected.
@Suite struct RemoteForwardTests {
    private func plan(kind: HarnessKind = .claude, shell: RemoteShell, remotePort: Int) -> String {
        Launcher.plan(kind: kind, paneName: "claude-1", host: "user@box", port: 7788, token: "tok", runnerModel: nil,
                      loginShell: "/bin/zsh", remoteShell: shell, remotePort: remotePort).args.joined(separator: " ")
    }

    @Test func aPaneForwardsItsOwnPortToTheBus() {
        for shell in [RemoteShell.posix, .windows] {
            let line = plan(shell: shell, remotePort: 50001)
            #expect(line.contains("50001:127.0.0.1:7788"), "\(shell)")
            #expect(!line.contains("7788:127.0.0.1:7788"), "\(shell)")
        }
    }

    /// What the host runs: on Windows the line travels as base64, past cmd.exe.
    private func onTheHost(_ shell: RemoteShell, remotePort: Int) throws -> String {
        let line = plan(shell: shell, remotePort: remotePort)
        guard shell == .windows else { return line }
        let head = "$^(echo ", tail = " ^| base64 -d^)"
        let start = try #require(line.range(of: head)).upperBound
        let end = try #require(line.range(of: tail)).lowerBound
        let data = try #require(Data(base64Encoded: String(line[start..<end])))
        return String(decoding: data, as: UTF8.self)
    }

    @Test func theHarnessOnTheHostIsToldThatPort() throws {
        for shell in [RemoteShell.posix, .windows] {
            let line = try onTheHost(shell, remotePort: 50001)
            #expect(line.contains("DOJO_PORT=50001"), "\(shell)")
            #expect(!line.contains("DOJO_PORT=7788"), "\(shell)")
            #expect(line.contains("127.0.0.1:50001/hook"), "\(shell)")
        }
    }

    /// The forward is asked for as on main, with no address named: a host whose sshd permits listening on
    /// `localhost` only would refuse 127.0.0.1 by name. What finds a dead tunnel is the pane's check, not
    /// ssh's complaint.
    @Test func theForwardIsAskedForAsOnMain() {
        for kind in [HarnessKind.claude, .codex, .pi, .shell, .runner] {
            for shell in [RemoteShell.posix, .windows] {
                let words = shellArgs(Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                                    runnerModel: nil, loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001,
                                                    runnerForward: kind == .runner ? 18081 : nil).args[3])
                let forward = words.firstIndex(of: "-R").map { words[$0 + 1] }
                #expect(forward == "50001:127.0.0.1:7788", "\(kind) \(shell)")
                #expect(words.filter { $0 == "-R" }.count == 1, "\(kind) \(shell)")
                #expect(words.contains("ServerAliveInterval=30") && words.contains("ServerAliveCountMax=3"), "\(kind) \(shell)")
            }
        }
    }

    /// The option that ends ssh on any forward that fails is for a Runner pane's own -L, as on main. On an
    /// agent pane it would also end the pane for a forward of the user's own in ~/.ssh/config: a second pane
    /// on a host alias with a LocalForward would never start.
    @Test func onlyARunnerPanesOwnForwardEndsThePaneWhenItFails() {
        for shell in [RemoteShell.posix, .windows] {
            for kind in [HarnessKind.claude, .codex, .pi, .shell] {
                let line = plan(kind: kind, shell: shell, remotePort: 50001)
                #expect(!line.contains("ExitOnForwardFailure"), "\(kind) \(shell)")
            }
            let runner = shellArgs(Launcher.plan(kind: .runner, paneName: "runner-1", host: "user@box", port: 7788, token: "tok",
                                                 runnerModel: nil, loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001,
                                                 runnerForward: 18081).args[3])
            #expect(runner.filter { $0 == "ExitOnForwardFailure=yes" }.count == 1, "\(shell)")
            // without a forward of its own a Runner pane has no such option either
            #expect(!plan(kind: .runner, shell: shell, remotePort: 50001).contains("ExitOnForwardFailure"), "\(shell)")
        }
    }

    /// A pane that reports hooks asks the bus for its own state through the tunnel before its harness starts,
    /// with its own port and token; a shell pane and a Runner pane, which report none, start as on main.
    @Test func aPaneThatReportsHooksChecksItsWayToTheBusFirst() throws {
        for shell in [RemoteShell.posix, .windows] {
            for kind in [HarnessKind.claude, .codex, .pi] {
                let inner = try hostsLine(kind, shell)
                let check = try #require(reachArgs(inner, home: "/remote/home"), "\(kind) \(shell)")
                // sh by its full path on a POSIX host: a profile there can leave /bin off the PATH
                #expect(check == ["env", "DOJO_PANE=\(kind)-1", "DOJO_PORT=50001", "DOJO_TOKEN=tok",
                                  "PATH=/remote/home/.dojo/bin:/usr/bin:/bin", shell == .posix ? "/bin/sh" : "sh", "-c", Launcher.reachCheck],
                        "\(kind) \(shell)")
                // the harness after it is given the same three and the same PATH
                #expect(Array(harnessArgs(inner, home: "/remote/home").prefix(5)) == Array(check.prefix(5)), "\(kind) \(shell)")
            }
            for kind in [HarnessKind.shell, .runner] {
                let inner = try hostsLine(kind, shell)
                #expect(!inner.contains("command -v dojo"), "\(kind) \(shell)")
                #expect(!inner.contains(" && exec "), "\(kind) \(shell): one command, as on main")
            }
        }
        // a pane on this Mac has no tunnel to check
        let local = Launcher.plan(kind: .claude, paneName: "claude-1", host: nil, port: 7788, token: "tok", runnerModel: nil,
                                  loginShell: "/bin/zsh").args.joined(separator: " ")
        #expect(!local.contains("command -v dojo"))
    }

    /// The line the host's login shell is started with, for a pane of this kind.
    private func hostsLine(_ kind: HarnessKind, _ shell: RemoteShell) throws -> String {
        let ssh = shellArgs(Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                          runnerModel: nil, loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001).args[3])
        let remote = try #require(ssh.last)
        if shell == .windows { return try #require(Launcher.windowsInnerCommand(remote)) }
        return try #require(shellArgs(remote, home: "/remote/home").last)
    }

    /// The check has no apostrophe and no backslash, which the quoting a fish login shell needs pays for
    /// dearly, and it is one line.
    @Test func theCheckIsCheapToQuote() {
        #expect(!Launcher.reachCheck.contains("'") && !Launcher.reachCheck.contains("\\") && !Launcher.reachCheck.contains("\n"))
    }

    /// The check goes by the pane's token, not its name: a pane renamed while it starts has a good tunnel.
    /// And it knows every state a bus can give.
    @Test func theCheckNamesNoPaneAndKnowsEveryState() {
        #expect(!Launcher.reachCheck.contains("DOJO_PANE"))
        #expect(Launcher.reachCheck.contains("dojo panes"))
        // the states, as one list in the place where the check reads the state
        let known = [PaneState.starting, .running, .idle, .prompt, .exited].map(\.rawValue).joined(separator: "|")
        #expect(Launcher.reachCheck.contains("case $word in " + known + ")"))
        // and every kind of pane a bus gives, from the bus's own list
        let kinds = HarnessKind.allCases.map(\.rawValue).joined(separator: "|")
        #expect(Launcher.reachCheck.contains("case $kind in " + kinds + ")"))
    }

    @Test func aLocalPaneKeepsTheBusPort() {
        let line = Launcher.plan(kind: .claude, paneName: "claude-1", host: nil, port: 7788, token: "tok", runnerModel: nil,
                                 loginShell: "/bin/zsh", remotePort: 50001).args.joined(separator: " ")
        #expect(line.contains("127.0.0.1:7788/hook"))
        #expect(!line.contains("50001"))
    }

    @Test func aNewPortIsNeverOneInUse() {
        let all = Set(Launcher.remotePorts)
        let taken = all.subtracting([50001])
        #expect(Launcher.remotePort(taken: taken) == 50001)
    }

    @Test func thePortsAreForAnyoneToBind() {
        #expect(Launcher.remotePorts.lowerBound > 1024)
        #expect(Launcher.remotePorts.upperBound <= 65535)
        #expect(!Launcher.remotePorts.contains(Launcher.defaultPort))
    }
}

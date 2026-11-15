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

    /// D35.2: ssh only warns when it cannot make a forward, and goes on. A pane without its tunnel has no
    /// hooks, so the bus would never learn of a prompt there; it ends with ssh's message instead.
    @Test func everyRemotePaneEndsWhenItsTunnelCannotBeMade() {
        for kind in [HarnessKind.claude, .codex, .pi, .shell, .runner] {
            for shell in [RemoteShell.posix, .windows] {
                let words = shellArgs(Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                                    runnerModel: nil, loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001,
                                                    runnerForward: kind == .runner ? 18081 : nil).args[3])
                let option = words.firstIndex(of: "ExitOnForwardFailure=yes")
                #expect(option != nil && words[(option ?? 1) - 1] == "-o", "\(kind) \(shell)")
                #expect(words.filter { $0 == "ExitOnForwardFailure=yes" }.count == 1, "\(kind) \(shell)")
                // an option of ssh's, so before the host
                #expect((option ?? .max) < (words.firstIndex(of: "user@box") ?? 0), "\(kind) \(shell)")
                // the tunnel and the keepalive are as they were
                #expect(words.contains("50001:127.0.0.1:7788") && words.contains("ServerAliveInterval=30")
                        && words.contains("ServerAliveCountMax=3"), "\(kind) \(shell)")
            }
        }
        // a pane on this Mac has no ssh at all
        let local = Launcher.plan(kind: .claude, paneName: "claude-1", host: nil, port: 7788, token: "tok", runnerModel: nil,
                                  loginShell: "/bin/zsh").args.joined(separator: " ")
        #expect(!local.contains("ExitOnForwardFailure"))
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

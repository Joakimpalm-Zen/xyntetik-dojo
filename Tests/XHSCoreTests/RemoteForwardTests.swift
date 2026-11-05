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

import Foundation
import Testing
@testable import XHSCore

/// A Runner pane on a host (D12): the same start script runs there, and the pane's own ssh connection
/// carries Runner's port back to this Mac, so the tunnel opens and closes with the pane.
@Suite struct RemoteRunnerTests {
    private func line(_ kind: HarnessKind, host: String?, shell: RemoteShell = .posix, runnerForward: Int? = nil,
                      runnerURL: String? = nil) -> String {
        Launcher.plan(kind: kind, paneName: "\(kind)-1", host: host, port: 7788, token: "tok", runnerModel: nil,
                      loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001, runnerForward: runnerForward,
                      runnerURL: runnerURL).args.joined(separator: " ")
    }

    @Test func aRemoteRunnerPaneForwardsRunnersPortToThisMac() {
        for shell in [RemoteShell.posix, .windows] {
            let words = line(.runner, host: "user@box", shell: shell, runnerForward: 18081)
            #expect(words.contains("-L 18081:127.0.0.1:8080"), "\(shell)")
            // the bus forward is still there beside it
            #expect(words.contains("-R 50001:127.0.0.1:7788"), "\(shell)")
        }
    }

    @Test func onlyARemoteRunnerPaneForwardsRunner() {
        #expect(!line(.claude, host: "user@box", runnerForward: 18081).contains("-L "))
        #expect(!line(.runner, host: nil, runnerForward: 18081).contains("-L "))
        #expect(!line(.runner, host: "user@box").contains("-L "))
    }

    @Test func theHostRunsTheSameStartScript() {
        #expect(line(.runner, host: "user@box", runnerForward: 18081).contains("runner-start.sh"))
    }

    @Test func aPiPaneOnThisMacIsToldWhichRunnerToUse() {
        func env(_ url: String?) -> [String: String] {
            Launcher.plan(kind: .pi, paneName: "pi-1", host: nil, port: 7788, token: "tok", runnerModel: nil,
                          loginShell: "/bin/zsh", runnerURL: url).environment
        }
        #expect(env("http://127.0.0.1:18081/v1")["DOJO_RUNNER_URL"] == "http://127.0.0.1:18081/v1")
        // without a choice it uses this Mac's Runner, as before: no variable at all
        #expect(env(nil)["DOJO_RUNNER_URL"] == nil)
    }

    @Test func theLocalForwardIsAFreePortOffRunnersOwn() {
        let port = Launcher.runnerForwardPort(taken: [], isFree: { $0 != Launcher.runnerForwardPorts.lowerBound })
        #expect(port != nil && port != Launcher.runnerForwardPorts.lowerBound)
        #expect(!Launcher.runnerForwardPorts.contains(8080))
        #expect(!Launcher.runnerForwardPorts.contains(Launcher.defaultPort))
        #expect(Launcher.runnerForwardPort(taken: Set(Launcher.runnerForwardPorts), isFree: { _ in true }) == nil)
    }

    @Test func aRemoteRunnersURLIsItsForward() {
        #expect(Launcher.runnerURL(forward: nil) == Launcher.runnerURL)
        #expect(Launcher.runnerURL(forward: 18081) == "http://127.0.0.1:18081/v1")
    }
}

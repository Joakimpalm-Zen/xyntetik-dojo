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
            // Dojo's own port on the host, never the host's 8080 (D12)
            #expect(words.contains("-L 18081:127.0.0.1:18080"), "\(shell)")
            #expect(!words.contains("127.0.0.1:8080"), "\(shell)")
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

    /// The harness line a remote pane runs on its host: decoded from base64 on Windows.
    private func harness(_ kind: HarnessKind, shell: RemoteShell, msysBash: String? = nil) -> String {
        let plan = Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                 runnerModel: nil, loginShell: "/bin/zsh", remoteShell: shell, remotePort: 50001,
                                 runnerForward: kind == .runner ? 18081 : nil, msysBash: msysBash)
        let remote = plan.args[3]
        return shell == .windows ? (Launcher.windowsInnerCommand(remote) ?? "") : remote
    }

    @Test func aRemoteRunnerServesOnDojosPortAndRaisesNoTray() {
        for shell in [RemoteShell.posix, .windows] {
            let line = harness(.runner, shell: shell)
            #expect(line.contains("DOJO_RUNNER_PORT=18080"), "\(shell)")
            #expect(line.contains("DOJO_RUNNER_TRAY=off"), "\(shell)")
        }
        // nor any other pane, and not this Mac's own Runner pane
        #expect(!harness(.claude, shell: .posix).contains("DOJO_RUNNER_PORT"))
        let local = Launcher.plan(kind: .runner, paneName: "runner-1", host: nil, port: 7788, token: "tok",
                                  runnerModel: nil, loginShell: "/bin/zsh")
        #expect(local.environment["DOJO_RUNNER_PORT"] == nil && local.environment["DOJO_RUNNER_TRAY"] == nil)
        #expect(!local.args.joined(separator: " ").contains("DOJO_RUNNER_TRAY"))
        #expect(Launcher.hostRunnerURL == "http://127.0.0.1:18080/v1")
        #expect(Launcher.remoteRunnerPort != Launcher.runnerPort)
    }

    @Test func aPiPaneOnAHostWithARunnerPaneUsesDojosPortThere() {
        let pi = Launcher.plan(kind: .pi, paneName: "pi-1", host: "user@box", port: 7788, token: "tok",
                               runnerModel: nil, loginShell: "/bin/zsh", remotePort: 50002,
                               runnerURL: Launcher.hostRunnerURL)
        #expect(pi.args[3].contains("DOJO_RUNNER_URL=http://127.0.0.1:18080/v1"))
        // a pi pane on a host has no -L: it is on the Runner's machine (the ssh words, before the host)
        let sshWords = pi.args[3].components(separatedBy: " user@box ").first ?? ""
        #expect(sshWords.hasPrefix("exec ssh -t -R 50002:127.0.0.1:7788"))
        #expect(!sshWords.contains("-L "))
    }

    @Test func aWindowsHostNamesItsMSYS2BashInTheSshSession() {
        // cmd.exe expanded the variable: that path is used
        let named = "Windows_NT C:\\localai\\Origin\\msys64\\usr\\bin\\bash.exe\r\n"
        #expect(RemoteShell.detect(probeOutput: named) == .windows)
        #expect(RemoteShell.msysBash(probeOutput: named) == #"C:\localai\Origin\msys64\usr\bin\bash.exe"#)
        // unset: cmd.exe leaves it as written, and the standard location is used
        #expect(RemoteShell.msysBash(probeOutput: "Windows_NT %DOJO_MSYS2_BASH%\r\n") == nil)
        #expect(RemoteShell.msysBash(probeOutput: "Windows_NT \r\n") == nil)
        // a POSIX host answers with the words as written
        #expect(RemoteShell.msysBash(probeOutput: "%OS% %DOJO_MSYS2_BASH%\n") == nil)
        // a path with a character cmd.exe would act on is not used
        #expect(RemoteShell.msysBash(probeOutput: "Windows_NT C:\\a&b\\bash.exe") == nil)
        #expect(RemoteShell.msysBash(probeOutput: #"Windows_NT C:\a"b\bash.exe"#) == nil)
        // the pane's command runs that bash; one with a space is quoted for cmd.exe
        let plain = Launcher.plan(kind: .claude, paneName: "claude-1", host: "box", port: 7788, token: "t",
                                  runnerModel: nil, loginShell: "/bin/zsh", remoteShell: .windows,
                                  msysBash: #"D:\tools\msys2\usr\bin\bash.exe"#).args[3]
        #expect(plain.contains(#"inherit&& D:\tools\msys2\usr\bin\bash.exe -lc "#))
        let spaced = Launcher.windowsRemoteCommand(inner: "true", bash: #"C:\local ai\bash.exe"#)
        #expect(spaced.hasPrefix(#"set MSYS2_PATH_TYPE=inherit&& "C:\local ai\bash.exe" -lc "#))
        #expect(Launcher.windowsRemoteCommand(inner: "true").hasPrefix(#"set MSYS2_PATH_TYPE=inherit&& C:\msys64\usr\bin\bash.exe -lc "#))
    }
}

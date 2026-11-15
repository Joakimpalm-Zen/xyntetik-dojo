import Foundation
import Testing
@testable import XHSCore

/// D35.2: a remote pane that reports hooks asks the bus for its own state through its tunnel before its
/// harness starts. Run for real, as the differential of D32 is: a stand-in for ssh and sshd, each shell here
/// as this Mac's login shell and as the host's, a stand-in harness that writes down what it saw, and a
/// stand-in for the shim on the host that answers as the real one does in each case.
@Suite struct RemoteReachTests {
    typealias Host = RemoteLoginShellTests.Host
    typealias Seen = RemoteLoginShellTests.Seen

    /// What the shim on the host does when it is asked for the pane's state.
    enum Shim: String, CaseIterable, Sendable {
        /// The bus answers.
        case answers = "echo \"claude-1 starting queued=0\"; exit 0"
        /// Nothing listens on the pane's port, or what listens is no bus: the real shim's words.
        case notReachable = "echo \"dojo: bus not reachable on 127.0.0.1:50001: <urlopen error [Errno 61] Connection refused>\" >&2; exit 1"
        /// Another Mac's bus answers, and does not know this pane's token: the real shim's words.
        case refused = "echo \"dojo: bus refused (401): unknown or missing X-Dojo-Token\" >&2; exit 1"
        /// A shim from before `state`.
        case old = "echo \"usage: dojo panes | send <name> <text>\" >&2; exit 2"
        /// A shim that cannot run: its Python is gone.
        case broken = "echo \"python3: command not found\" >&2; exit 127"
        /// A shim that fails in a way of its own.
        case crashes = "echo \"Traceback (most recent call last):\" >&2; exit 1"

        var endsThePane: Bool { self == .notReachable || self == .refused }
    }

    /// One run: what the harness saw, what the shim was asked, how the pane ended and what it said.
    struct Run: Sendable {
        let seen: Seen?
        let asked: [String]
        let status: Int32
        let errors: String
    }

    static func run(_ host: Host, kind: HarnessKind = .claude, folder: String? = "two words", main: Bool = false,
                    stage: RemoteLoginShellTests.Stage) throws -> Run {
        let asked = host.seen.path + ".dojo"
        try? host.fm.removeItem(atPath: asked)
        let seen = try host.run(host.command(kind: kind, folder: folder, main: main), local: stage.local, remote: stage.remote)
        let lines = ((try? String(contentsOfFile: asked, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return Run(seen: seen, asked: lines, status: host.lastStatus, errors: host.lastErrors)
    }

    static func install(_ shim: Shim?, on host: Host) throws {
        let path = host.remoteHome.appendingPathComponent(".dojo/bin/dojo")
        try? host.fm.removeItem(at: path)
        guard let shim else { return }
        try host.script(path, [
            "printf '%s\\n' \"$*\" \"$DOJO_PANE $DOJO_PORT $DOJO_TOKEN\" > \"$DOJO_TEST_SEEN.dojo\"",
            shim.rawValue,
        ].joined(separator: "\n"))
    }

    /// Every shell, as this Mac's login shell and as the host's: where the bus answers, where the host has
    /// no shim, and where the shim is old, broken or fails in its own way, the harness starts with exactly
    /// what main's command gives it. Where the shim says the bus is not reachable or refused the pane, the
    /// harness does not start and the pane says why.
    @Test(arguments: RemoteLoginShellTests.stages)
    func thePaneStartsAsOnMainUnlessTheShimSaysTheBusIsNotThere(stage: RemoteLoginShellTests.Stage) async throws {
        let host = try Host()
        let (main, none, runs): (Run, Run, [(Shim, Run)]) = try await awayFromTheTests {
            let main = try Self.run(host, main: true, stage: stage)
            let none = try Self.run(host, stage: stage)
            var runs: [(Shim, Run)] = []
            for shim in Shim.allCases {
                try Self.install(shim, on: host)
                runs.append((shim, try Self.run(host, stage: stage)))
            }
            return (main, none, runs)
        }
        // fish cannot read main's command at all (D32), so there the new command is held to what it gives
        // the harness with no shim on the host
        let before = try #require(main.seen ?? none.seen, "\(stage): the harness did not start")
        #expect(none.seen == before, "\(stage): no shim on the host")
        #expect(none.asked.isEmpty)
        for (shim, run) in runs {
            let what = "\(stage), the shim \(shim)"
            #expect(run.asked == ["state claude-1", "claude-1 50001 tok"], "\(what): asked for this pane's state, with its port and token")
            if shim.endsThePane {
                #expect(run.seen == nil, "\(what): the harness must not start")
                #expect(run.status != 0, "\(what): the pane ends as failed")
                #expect(run.errors.contains("Dojo: the bus could not be reached through the tunnel of this pane, so the pane does not start. bus "),
                        "\(what): \(run.errors)")
                #expect(!run.errors.contains("dojo: bus"), "\(what): the shim's own prefix is taken off")
            } else {
                #expect(run.seen == before, "\(what)")
                #expect(!run.errors.contains("could not be reached"), "\(what)")
            }
        }
    }

    /// A Runner pane on a host reports no hooks: the shim is not asked, whatever it would say.
    @Test func aRunnerPaneDoesNotAsk() async throws {
        let host = try Host()
        try Self.install(.refused, on: host)
        let stage = RemoteLoginShellTests.Stage(local: "/bin/sh", remote: "/bin/sh")
        let (main, new) = try await awayFromTheTests {
            (try Self.run(host, kind: .runner, main: true, stage: stage), try Self.run(host, kind: .runner, stage: stage))
        }
        #expect(main.seen != nil)
        #expect(new.seen == main.seen)
        #expect(new.asked.isEmpty)
    }

    /// The check on its own, read by every POSIX shell here as `sh`: its exit and what it says.
    @Test func theCheckEndsOnlyOnTheShimsTwoMessages() async throws {
        let host = try Host()
        let shells = RemoteLoginShellTests.posixShells.filter { FileManager.default.isExecutableFile(atPath: $0) }
        let results: [(String, Shim?, Int32, String)] = try await awayFromTheTests {
            var results: [(String, Shim?, Int32, String)] = []
            for shell in shells {
                for shim in [nil] + Shim.allCases.map({ Optional($0) }) {
                    try Self.install(shim, on: host)
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-c", Launcher.reachCheck]
                    process.environment = ["PATH": host.remoteHome.appendingPathComponent(".dojo/bin").path + ":/usr/bin:/bin",
                                           "DOJO_PANE": "claude-1", "DOJO_PORT": "50001", "DOJO_TOKEN": "tok",
                                           "DOJO_TEST_SEEN": host.seen.path]
                    let errors = Pipe()
                    process.standardError = errors
                    process.standardOutput = FileHandle.nullDevice
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let said = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    results.append((shell, shim, process.terminationStatus, said))
                }
            }
            return results
        }
        #expect(results.count == shells.count * (Shim.allCases.count + 1))
        for (shell, shim, status, said) in results {
            let what = "\(shell), the shim \(shim.map { "\($0)" } ?? "absent")"
            if shim?.endsThePane == true {
                #expect(status == 1, "\(what)")
                #expect(said.hasPrefix("Dojo: the bus could not be reached through the tunnel of this pane, so the pane does not start. bus "), "\(what): \(said)")
                #expect(said.split(separator: "\n").count == 1, "\(what): one line")
            } else {
                #expect(status == 0, "\(what)")
                #expect(said.isEmpty, "\(what): \(said)")
            }
        }
    }
}

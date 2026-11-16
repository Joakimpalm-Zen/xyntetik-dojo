import Foundation
import Testing
@testable import XHSCore

/// D35.2: a remote pane that reports hooks asks the bus through its tunnel, before its harness starts,
/// whether it knows this pane. Run for real, as the differential of D32 is: a stand-in for ssh and sshd, each
/// shell here as this Mac's login shell and as the host's, a stand-in harness that writes down what it saw,
/// and a stand-in for the shim on the host that answers as the real one does in each case.
@Suite struct RemoteReachTests {
    typealias Host = RemoteLoginShellTests.Host
    typealias Seen = RemoteLoginShellTests.Seen

    /// What the shim on the host does when it is asked for the panes.
    enum Shim: String, CaseIterable, Sendable {
        /// The bus answers, and marks this pane as the caller's own.
        case answers = "printf '%s\\n' '  fable        claude local          idle     queued=0 claude-fable-5-2' '* claude-1     claude box            starting queued=0 '; exit 0"
        /// The pane was renamed while it started: the bus knows it by its token, under another name.
        case renamed = "printf '%s\\n' '* new-name     claude box            starting queued=0 '; exit 0"
        /// Nothing listens on the pane's port: the real shim's words.
        case notReachable = "echo 'dojo: bus not reachable on 127.0.0.1:50001: <urlopen error [Errno 61] Connection refused>' >&2; exit 1"
        /// Another Mac's bus answers, and does not know this pane's token: the real shim's words.
        case refused = "echo 'dojo: bus refused (401): unknown or missing X-Dojo-Token' >&2; exit 1"
        /// A program that is no bus refuses, and its answer repeats the request's headers.
        case refusedEchoingTheToken = "echo 'dojo: bus refused (401): request rejected; X-Dojo-Token: D104_SYNTHETIC_SECRET' >&2; exit 1"
        /// A web server on the port: its refusal says "not found", which is not the sign of a missing Python.
        case pageNotFound = "echo 'dojo: bus refused (404): 404 page not found' >&2; exit 1"
        /// A program that is no bus answers 200 with a web page: the real shim's words for that.
        case html = "echo 'dojo: Expecting value: line 1 column 1 (char 0)' >&2; exit 1"
        /// A program that is no bus answers 200 with an empty object: the shim prints no pane and succeeds.
        case emptyAnswer = "exit 0"
        /// An answer with panes in it, none of them the caller's own.
        case noMark = "printf '%s\\n' '  fable        claude local          idle     queued=0 '; exit 0"
        /// The caller's own pane in a state no bus gives.
        case unknownState = "printf '%s\\n' '* claude-1     claude box            None     queued=0 '; exit 0"
        /// The shim fails in a way of its own.
        case crashes = "echo 'Traceback (most recent call last):' >&2; echo 'SyntaxError: invalid syntax' >&2; exit 1"
        /// A program that is no bus answers with a pane that has no name and a state word as its host: the
        /// real shim marks it (no name equals no caller) and prints this.
        case aStateWordInAnotherColumn = "printf '%s\n' '* None         None   idle           None     queued=0 '; exit 0"
        /// The same with names: the name is a state word, the state is none a bus gives.
        case aStateWordAsTheName = "printf '%s\n' '* idle         None   local          bogus    queued=0 '; exit 0"
        /// A listener answers 404 with a list as its body: the real shim crashes on it, and its traceback
        /// holds the words "not found", which are not the sign of a missing Python.
        case aTracebackThatSaysNotFound = "echo 'Traceback (most recent call last):' >&2; echo 'urllib.error.HTTPError: HTTP Error 404: File not found' >&2; echo 'AttributeError: list object has no attribute get' >&2; exit 1"
        /// A shell's "not found" with a status that is not the one for a command that is not there.
        case notFoundWithAnotherStatus = "echo '/opt/dojo/bin/dojo: 2: exec: python3: not found' >&2; exit 126"
        /// The status of a command that is not there, from a shim that spoke for itself.
        case theShimSpokeAndGave127 = "echo 'dojo: bus not reachable on 127.0.0.1:50001: refused' >&2; exit 127"
        /// A usage line that is not the first line, and a usage line with another status.
        case usageNotFirst = "echo 'Traceback (most recent call last):' >&2; echo 'usage: dojo send <name>' >&2; exit 2"
        case usageWithAnotherStatus = "echo 'usage: dojo send <name> <text...>' >&2; exit 1"
        /// The host's Python prints a starred line of its own when it starts, and the bus answers.
        case aBannerBeforeTheAnswer = "printf '%s\n' '* Python environment ready' '* renamed      claude box            starting queued=0 '; exit 0"
        /// The caller's own line with a label that itself holds the word queued=.
        case aLabelThatSaysQueued = "printf '%s\n' '* claude-1     claude box            running  queued=0 m label=3 queued=None idle'; exit 0"
        /// A starred banner and no answer.
        case aBannerAndNoAnswer = "printf '%s\n' '* idle queued=0 is what this banner says' '  fable        claude local          idle     queued=0 '; exit 0"
        /// A shim from before the call: its usage error.
        case old = "echo 'usage: dojo send <name> <text...> | read <name> [lines]' >&2; exit 2"
        /// A shim that cannot run: its Python is gone, in the words of env and of a shell.
        case noPython = "echo 'env: python3: No such file or directory' >&2; exit 127"
        case noPythonInAShellsWords = "echo '/opt/dojo/bin/dojo: 2: exec: python3: not found' >&2; exit 127"

        /// Whether the harness starts: on an answer that shows a bus that knows this pane, and in the two
        /// cases that are recognised by their own sign as a host that has no hooks today either.
        var starts: Bool {
            switch self {
            case .answers, .renamed, .aBannerBeforeTheAnswer, .aLabelThatSaysQueued, .old, .noPython, .noPythonInAShellsWords: return true
            default: return false
            }
        }

        /// The end of the pane's line where it does not start: fixed words, and the status number alone.
        var says: String {
            switch self {
            case .notReachable, .theShimSpokeAndGave127: return "bus not reachable."
            case .refused, .refusedEchoingTheToken: return "bus refused (401)."
            case .pageNotFound: return "bus refused (404)."
            default: return "the answer was not from a bus that knows this pane."
            }
        }
    }

    static let line = "Dojo: the bus could not be reached through the tunnel of this pane, so the pane does not start: "

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
            "printf '%s\\n' \"$*\" \"$DOJO_PORT $DOJO_TOKEN\" > \"$DOJO_TEST_SEEN.dojo\"",
            shim.rawValue,
        ].joined(separator: "\n"))
    }

    /// Every shell, as this Mac's login shell and as the host's. The harness starts, with exactly what main's
    /// command gives it, on an answer that shows a bus that knows this pane, and on a host with no shim, an
    /// old one or no Python. Every other answer from a shim ends the pane with the line.
    @Test(arguments: RemoteLoginShellTests.stages)
    func thePaneStartsOnlyOnABusThatKnowsItOrOnAHostWithNoHooks(stage: RemoteLoginShellTests.Stage) async throws {
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
            #expect(run.asked == ["panes", "50001 tok"], "\(what): asked by the pane's port and token, with no name")
            #expect(!run.errors.contains("D104_SYNTHETIC_SECRET") && !run.errors.contains("X-Dojo-Token"), "\(what): the shim's words are not shown")
            if shim.starts {
                #expect(run.seen == before, "\(what)")
                #expect(!run.errors.contains("could not be reached"), "\(what)")
            } else {
                #expect(run.seen == nil, "\(what): the harness must not start")
                #expect(run.status != 0, "\(what): the pane ends as failed")
                #expect(run.errors.contains(Self.line + shim.says), "\(what): \(run.errors)")
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

    /// A host whose login profile puts env and the harness on the PATH and leaves /bin off it: main starts
    /// there, and so must the pane with its check, which names sh by its full path.
    @Test func aHostWhosePathHasNoShStartsAsOnMain() async throws {
        let host = try Host()
        let bin = host.root.appendingPathComponent("env-only")
        try host.fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try host.fm.createSymbolicLink(atPath: bin.appendingPathComponent("env").path, withDestinationPath: "/usr/bin/env")
        let (main, new) = try await awayFromTheTests {
            (try host.run(host.command(kind: .claude, folder: "plain", main: true), local: "/bin/sh", remote: host.plainLogin.path, remotePath: bin.path),
             try host.run(host.command(kind: .claude, folder: "plain", main: false), local: "/bin/sh", remote: host.plainLogin.path, remotePath: bin.path))
        }
        let before = try #require(main, "main's command must reach the harness for this test to say anything")
        #expect(new == before)
    }

    /// The check on its own, read by every POSIX shell here: its exit and what it says.
    @Test func theCheckByItself() async throws {
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
            if shim?.starts ?? true {
                #expect(status == 0, "\(what)")
                #expect(said.isEmpty, "\(what): \(said)")
            } else {
                #expect(status == 1, "\(what)")
                #expect(said == Self.line + (shim?.says ?? "") + "\n", "\(what): \(said)")
            }
        }
    }
}

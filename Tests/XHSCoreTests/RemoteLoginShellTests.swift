import Foundation
import Testing
@testable import XHSCore

/// D32: a remote pane on a host whose login shell is fish. The command for a remote pane is read by three
/// shells in turn: this Mac's login shell (which starts ssh), the account's login shell on the host (which
/// sshd hands the command), and that login shell again, started with `-l -i`, which changes folder and
/// starts the harness. Any of them may be fish, which reads a backslash before an apostrophe inside single
/// quotes as an escape, and two backslashes there as one, where a POSIX shell reads both as written.
///
/// The acceptance test is a differential against main: whatever reaches the harness with main's command
/// must reach it after the change, in the same folder, with the same arguments and the same environment.
/// Only the cases that fail on main may differ. The commands run for real, with a stand-in for ssh and sshd
/// and a stand-in harness that writes down what it saw.
@Suite struct RemoteLoginShellTests {
    static let posixShells = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh"]
    static let fishPaths = ["/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"]
    static let shellsHere = (posixShells + fishPaths).filter { FileManager.default.isExecutableFile(atPath: $0) }

    /// Which shell reads the command on this Mac and which on the host.
    struct Stage: Sendable, CustomStringConvertible {
        let local: String
        let remote: String
        var description: String { "local \(local), remote \(remote)" }
        var hasFish: Bool { local.hasSuffix("/fish") || remote.hasSuffix("/fish") }
    }

    /// Each shell here once as the Mac's login shell and once as the host's, with sh on the other side.
    static let stages: [Stage] = shellsHere.map { Stage(local: $0, remote: "/bin/sh") }
        + shellsHere.dropFirst().map { Stage(local: "/bin/sh", remote: $0) }

    /// What the stand-in harness saw.
    struct Seen: Equatable, Sendable {
        let folder: String
        let argv: [String]
        let environment: [String]
    }

    /// A Mac and a host in one temporary folder: a home for each, folders to start in on the host, a stand-in
    /// for ssh and sshd, and stand-ins for the harness and for Runner's start script.
    final class Host: @unchecked Sendable {
        /// `%self` is given to the pane as a relative path, so that the word the shells read starts with it:
        /// fish puts its own process id for a bare word that does.
        static let folderNames = ["plain", "two words", "it's", "end\\", "répo", "%self", "x==sh"]
        /// `x==sh` is given the same way: a zsh with MAGIC_EQUAL_SUBST on reads the bare word as x= and the
        /// path of sh.
        static let relative: Set<String> = ["%self", "x==sh"]

        let fm = FileManager.default
        /// How the last run ended and what it wrote to the pane as errors.
        var lastStatus: Int32 = 0
        var lastErrors = ""
        let root: URL
        let localHome: URL
        let remoteHome: URL
        let sshStandIn: URL
        /// A login shell that reads no profile: sh, whatever it is started with.
        let plainLogin: URL
        let seen: URL

        /// `harnessInToolsOf`: the harness is only in that folder's `tools`, where a directory hook of the
        /// login shell puts it on the PATH; otherwise it is in ~/.dojo/bin, beside Runner's start script.
        init(harnessInToolsOf folder: String? = nil) throws {
            root = fm.temporaryDirectory.appendingPathComponent("dojo-host-\(UUID().uuidString)")
            localHome = root.appendingPathComponent("local")
            remoteHome = root.appendingPathComponent("remote")
            sshStandIn = root.appendingPathComponent("ssh-stand-in")
            plainLogin = root.appendingPathComponent("login-plain")
            seen = root.appendingPathComponent("seen")
            try fm.createDirectory(at: localHome, withIntermediateDirectories: true)
            for name in Host.folderNames {
                try fm.createDirectory(at: remoteHome.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            let recorder = [
                "pwd > \"$DOJO_TEST_SEEN.folder\"",
                "for a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$DOJO_TEST_SEEN.argv\"",
                "env > \"$DOJO_TEST_SEEN.env\"",
            ].joined(separator: "\n")
            if let folder {
                let tools = remoteHome.appendingPathComponent(folder).appendingPathComponent("tools")
                try fm.createDirectory(at: tools, withIntermediateDirectories: true)
                try script(tools.appendingPathComponent("claude"), recorder)
            } else {
                try fm.createDirectory(at: remoteHome.appendingPathComponent(".dojo/bin"), withIntermediateDirectories: true)
                try script(remoteHome.appendingPathComponent(".dojo/bin/claude"), recorder)
                try script(remoteHome.appendingPathComponent(".dojo/runner-start.sh"), recorder)
            }
            // ssh and sshd in one: the last word is the remote command, and the account's login shell on the
            // host gets it with -c, in the account's home.
            try script(sshStandIn, [
                "for a in \"$@\"; do last=$a; done",
                "HOME=$DOJO_TEST_REMOTE_HOME; SHELL=$DOJO_TEST_REMOTE_SHELL; PATH=$DOJO_TEST_REMOTE_PATH",
                "export HOME SHELL PATH",
                "cd \"$HOME\" || exit 1",
                "exec \"$SHELL\" -c \"$last\"",
            ].joined(separator: "\n"))
            // A directory hook, as an account may have one: zsh runs chpwd whenever it changes folder, and what
            // the hook exports is part of what the harness sees.
            try Data("chpwd() { export DOJO_TEST_HOOK=\"$PWD\" }\n".utf8).write(to: remoteHome.appendingPathComponent(".zshrc"))
            try script(plainLogin, [
                "while [ \"$1\" = \"-l\" ] || [ \"$1\" = \"-i\" ]; do shift; done",
                "exec /bin/sh \"$@\"",
            ].joined(separator: "\n"))
        }

        deinit { try? fm.removeItem(at: root) }

        func script(_ url: URL, _ body: String) throws {
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func path(of folder: String?) -> String {
            folder.map { remoteHome.appendingPathComponent($0).path } ?? remoteHome.path
        }

        /// The command this Mac's login shell is given for a pane on the host: as the code under test builds
        /// it, or as main builds it (`mainsCommand`: from `harnessWords`, `Shell.line`, `Shell.quote` and
        /// `Shell.homeQuoted`, which the changes leave as they are, and main's ssh words written out).
        func command(kind: HarnessKind, folder: String?, main: Bool) -> String {
            let directory = folder.map { Host.relative.contains($0) ? $0 : path(of: $0) }
            guard main else {
                return Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                     runnerModel: nil, loginShell: "/bin/zsh", directory: directory, remotePort: 50001,
                                     runnerForward: kind == .runner ? 18081 : nil).args[3]
            }
            return RemoteLoginShellTests.mainsCommand(kind: kind, directory: directory)
        }

        /// Runs the command as the app does: `local` reads it as a login shell, the stand-in ssh hands the
        /// remote command to `remote`, the host's login shell. Nil when the stand-in harness never started.
        func run(_ command: String, local: String, remote: String, remotePath: String = "/usr/bin:/bin",
                 extra: [String: String] = [:]) throws -> Seen? {
            for part in ["folder", "argv", "env"] { try? fm.removeItem(atPath: seen.path + "." + part) }
            guard command.hasPrefix("exec ssh ") else { return nil }
            var environment = ["HOME": localHome.path, "PATH": "/usr/bin:/bin", "SHELL": local, "LANG": "en_US.UTF-8",
                               "DOJO_TEST_REMOTE_HOME": remoteHome.path, "DOJO_TEST_REMOTE_SHELL": remote,
                               "DOJO_TEST_REMOTE_PATH": remotePath, "DOJO_TEST_SEEN": seen.path]
            for (key, value) in extra { environment[key] = value }
            let errors = root.appendingPathComponent("errors-\(UUID().uuidString)")
            fm.createFile(atPath: errors.path, contents: nil)
            // In a session of its own, as helpLists starts its shell: with Process, an interactive login shell
            // is in a background group of the terminal `swift test` was run from, and stops there (the second
            // read of #114: 30 seconds a case, from an agy pane's shell tool).
            let shell = ["-l", "-i", "-c", "exec " + sshStandIn.path + " " + String(command.dropFirst("exec ssh ".count))]
            guard let child = Launcher.Detached(local, shell, environment: environment, errors: errors.path, qos: QOS_CLASS_UTILITY) else {
                throw CocoaError(.executableLoad)
            }
            let stuck = DispatchWorkItem { child.stop() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: stuck)
            _ = child.output.readDataToEndOfFile()
            child.outputEnded()
            lastStatus = child.exitCode()
            stuck.cancel()
            lastErrors = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            guard let folder = fm.contents(atPath: seen.path + ".folder"), let argv = fm.contents(atPath: seen.path + ".argv"),
                  let env = fm.contents(atPath: seen.path + ".env") else { return nil }
            var words = String(decoding: argv, as: UTF8.self).components(separatedBy: "\0")
            if words.last == "" { words.removeLast() }
            // `_` is the shell's note of the last command it ran, not part of what the harness is given
            let lines = String(decoding: env, as: UTF8.self).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("_=") }
            return Seen(folder: String(decoding: folder, as: UTF8.self).trimmingCharacters(in: .newlines), argv: words,
                        environment: lines.sorted())
        }

        func same(_ a: String, _ b: String) -> Bool {
            URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        }
    }

    /// Main's command for a remote pane, put together from the parts main's `Launcher.plan` uses, in its order,
    /// as it was before D32 and D35.2. `since352` gives it the one thing D35.2 changes, and nothing else: a
    /// pane that reports hooks first checks its way to the bus.
    static func mainsCommand(kind: HarnessKind, directory: String?, windows: Bool = false, since352: Bool = false) -> String {
        var assignments = ["DOJO_PANE=\(kind)-1", "DOJO_PORT=50001", "DOJO_TOKEN=tok"]
        if kind == .runner { assignments += ["DOJO_RUNNER_PORT=\(Launcher.remoteRunnerPort)", "DOJO_RUNNER_TRAY=off"] }
        let harness = Launcher.harnessWords(kind: kind, paneName: "\(kind)-1", port: 50001, runnerModel: nil)
        let env: [ShellWord] = [.literal("env")] + assignments.map { ShellWord.literal($0) } + [.raw(#"PATH="$HOME/.dojo/bin:$PATH""#)]
        let reach = since352 && Launcher.reportsHooks.contains(kind)
            ? Shell.line(env + [.literal(windows ? "sh" : "/bin/sh"), .literal("-c"), .literal(Launcher.reachCheck)]) + " && " : ""
        let inner = (directory.map { "cd " + Shell.homeQuoted($0) + " && " } ?? "") + reach + "exec " + Shell.line(env + harness)
        let remote = windows ? Launcher.windowsRemoteCommand(inner: inner) : #"exec "$SHELL" -l -i -c "# + Shell.quote(inner)
        var ssh: [ShellWord] = [.literal("ssh"), .literal("-t"), .literal("-R"), .literal("50001:127.0.0.1:7788")]
        if kind == .runner {
            ssh += [.literal("-L"), .literal("18081:127.0.0.1:\(Launcher.remoteRunnerPort)"), .literal("-o"), .literal("ExitOnForwardFailure=yes")]
        }
        ssh += [.literal("-o"), .literal("ServerAliveInterval=30"), .literal("-o"), .literal("ServerAliveCountMax=3"),
                .literal("user@box"), .literal(remote)]
        return "exec " + Shell.line(ssh)
    }

    /// A Windows host's command is read by cmd.exe and MSYS2 bash, never by fish. D32 did not touch it, and
    /// D35.2 changes one thing in it and nothing else: character for character it is main's with, for a
    /// pane that reports hooks, the check of its way to the bus.
    @Test func aWindowsHostsCommandIsMainsToTheLetterButForTheCheck() {
        for kind in [HarnessKind.claude, .codex, .pi, .runner, .shell] {
            for folder in [nil, #"C:\Users\me\it's here"#] as [String?] {
                let now = Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                        runnerModel: nil, loginShell: "/bin/zsh", remoteShell: .windows, directory: folder,
                                        remotePort: 50001, runnerForward: kind == .runner ? 18081 : nil).args[3]
                #expect(now == Self.mainsCommand(kind: kind, directory: folder, windows: true, since352: true), "\(kind), folder \(folder ?? "none")")
                // a pane without hooks is main's to the letter
                if !Launcher.reportsHooks.contains(kind) {
                    #expect(now == Self.mainsCommand(kind: kind, directory: folder, windows: true), "\(kind), folder \(folder ?? "none")")
                }
            }
        }
    }

    static let kinds: [HarnessKind] = [.claude, .runner]
    static let folders: [String?] = [nil] + Host.folderNames.map { Optional($0) }

    /// One case of the differential: what the stand-in harness saw with main's command and with the new one.
    struct Case: Sendable {
        let kind: HarnessKind
        let folder: String?
        let before: Seen?
        let after: Seen?
    }

    /// The differential. For each shell as this Mac's login shell and as the host's, each kind of pane and
    /// each folder: what main's command reaches, the new command reaches the same way.
    @Test(arguments: stages)
    func whatReachesTheHarnessOnMainReachesItTheSameWay(stage: Stage) async throws {
        let host = try Host()
        let cases = try await awayFromTheTests {
            try Self.kinds.flatMap { kind in
                try Self.folders.map { folder in
                    Case(kind: kind, folder: folder,
                         before: try host.run(host.command(kind: kind, folder: folder, main: true), local: stage.local, remote: stage.remote),
                         after: try host.run(host.command(kind: kind, folder: folder, main: false), local: stage.local, remote: stage.remote))
                }
            }
        }
        var onMain = 0
        for run in cases {
            let what = "\(run.kind), folder \(run.folder ?? "none"), \(stage)"
            if let before = run.before {
                onMain += 1
                #expect(run.after?.folder == before.folder, "\(what)")
                #expect(run.after?.argv == before.argv, "\(what)")
                #expect(run.after?.environment == before.environment, "\(what)")
                // the host's zsh ran its directory hook on main, so the comparison covers it
                if stage.remote == "/bin/zsh", run.folder != nil {
                    #expect(before.environment.contains { $0.hasPrefix("DOJO_TEST_HOOK=") }, "\(what)")
                }
            }
            // And the new command on its own terms, which is all there is to go by where main fails:
            // the harness starts, in the folder asked for (the home when none is), with what it is given.
            let seen = try #require(run.after, "\(what): the harness did not start")
            #expect(host.same(seen.folder, host.path(of: run.folder)), "\(what)")
            if run.kind == .claude {
                let prompt = seen.argv.firstIndex(of: "--append-system-prompt").map { seen.argv[$0 + 1] }
                #expect(prompt == PeerRule.launchPrompt(paneName: "claude-1"), "\(what)")
                #expect(seen.environment.contains("DOJO_TOKEN=tok") && seen.environment.contains("DOJO_PORT=50001"), "\(what)")
            } else {
                #expect(seen.argv.isEmpty && seen.environment.contains("DOJO_RUNNER_TRAY=off"), "\(what)")
            }
        }
        print("D32 differential, \(stage): main's command reached the harness in \(onMain) of \(cases.count) cases")
        // Without a case that works on main the comparison would say nothing.
        if !stage.hasFish { #expect(onMain > 0, "\(stage)") }
    }

    /// A directory hook of the login shell (zsh's chpwd) runs when the pane changes into its folder, and
    /// what it exports reaches the harness: here the harness is found only through the PATH the hook sets.
    @Test func aDirectoryHookOfTheLoginShellStillRuns() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let host = try Host(harnessInToolsOf: "plain")
        try Data("chpwd() { export DOJO_TEST_HOOK=\"$PWD\"; export PATH=\"$PWD/tools:$PATH\" }\n".utf8)
            .write(to: host.remoteHome.appendingPathComponent(".zshrc"))
        let (main, new) = try await awayFromTheTests {
            (try host.run(host.command(kind: .claude, folder: "plain", main: true), local: "/bin/sh", remote: "/bin/zsh"),
             try host.run(host.command(kind: .claude, folder: "plain", main: false), local: "/bin/sh", remote: "/bin/zsh"))
        }
        let before = try #require(main, "main's command must reach the harness through the hook for this test to say anything")
        #expect(before.environment.contains { $0.hasPrefix("DOJO_TEST_HOOK=") })
        #expect(new == before)
    }

    /// A host with nothing on its PATH but sh and env, and one that also has a python3 whose output is ASCII
    /// only: main's command needs no tool to get the harness line across, so neither may the new one.
    @Test func aHostWithNoToolsBesideShAndEnvStartsAsOnMain() async throws {
        let host = try Host()
        let bin = host.root.appendingPathComponent("bare-bin")
        try host.fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try host.fm.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path, withDestinationPath: "/bin/sh")
        try host.fm.createSymbolicLink(atPath: bin.appendingPathComponent("env").path, withDestinationPath: "/usr/bin/env")
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { host.fm.isExecutableFile(atPath: $0) }
        let runs: [(what: String, before: Seen?, after: Seen?)] = try await awayFromTheTests {
            var runs: [(what: String, before: Seen?, after: Seen?)] = []
            for withPython in [false, true] {
                var extra: [String: String] = [:]
                if withPython {
                    guard let python else { continue }
                    try host.script(bin.appendingPathComponent("python3"), "exec \(python) \"$@\"")
                    extra["PYTHONIOENCODING"] = "ascii"
                }
                for folder in ["plain", "répo"] {
                    runs.append(("folder \(folder), python3 \(withPython ? "with ASCII output" : "absent")",
                                 try host.run(host.command(kind: .claude, folder: folder, main: true), local: "/bin/sh",
                                              remote: host.plainLogin.path, remotePath: bin.path, extra: extra),
                                 try host.run(host.command(kind: .claude, folder: folder, main: false), local: "/bin/sh",
                                              remote: host.plainLogin.path, remotePath: bin.path, extra: extra)))
                }
            }
            return runs
        }
        #expect(runs.count >= 2)
        for run in runs {
            let before = try #require(run.before, "\(run.what): main's command must reach the harness for this test to say anything")
            #expect(run.after == before, "\(run.what)")
        }
    }

    /// With no fish on the machine its reading rule stands in for it: the command at each of the three levels
    /// must split into the same words for fish as for sh, for every kind of pane and awkward folder names.
    @Test func everyLevelSplitsTheSameForFishAsForSh() throws {
        let folders: [String?] = [nil, "/srv/plain", "/srv/two words", "/srv/it's", "/srv/end\\", "/srv/a\\\\b", "/srv/répo", "~/my repo",
                                  "%self", "%self/work", "50%"]
        // agy (D38): its launch carries the peer rule as one KEY=value word for env
        for kind in [HarnessKind.claude, .codex, .pi, .agy, .runner, .shell] {
            for folder in folders {
                let what = "\(kind), folder \(folder ?? "none")"
                let local = Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                          runnerModel: nil, loginShell: "/bin/zsh", directory: folder, remotePort: 50001,
                                          runnerForward: kind == .runner ? 18081 : nil).args[3]
                // this Mac's login shell
                let first = try #require(Fish.words(local), "\(what): fish cannot read the command this Mac's login shell is given")
                #expect(first == Posix.words(local), "\(what)")
                #expect(first == ["exec"] + shellArgs(local), "\(what): the reader and sh itself disagree")
                // the login shell on the host
                let remote = try #require(first.last)
                let second = try #require(Fish.words(remote), "\(what): fish cannot read the command ssh carries")
                #expect(second == Posix.words(remote), "\(what)")
                // the login shell again, started to change folder and start the harness
                let inner = try #require(second.last)
                let third = try #require(Fish.words(inner), "\(what): fish cannot read the command the login shell is started with")
                #expect(third == Posix.words(inner), "\(what)")
            }
        }
    }

    /// The quoting on its own: every shell here reads each word back as it was, quoted once and quoted
    /// again, as a command that crosses two shells is.
    @Test func everyShellHereReadsAQuotedWordBackAsItWas() async throws {
        let words = ["", "plain", "two words", "it's", "end\\", "a\\\\b", "\\'", "'\\", "''", "\\\\'\\", "$HOME \"q\" `x` $(y)",
                     "répo ☺", "line one\nline two", "~/x", "*?[a]{b,c}", "%OS%", "#c", "a;b|c&d<e>f(g)", "=cmd", "!bang", "-n", " lead and trail ",
                     "%self", "%self/x", "%", "50%", "a@b_c+d=e:f,g.h/i-j", "@home", "+x", ":x", ",x", ".x", "/x", "_x"]
        let line = "/usr/bin/printf '%s\\0' " + words.map(Shell.quoteAnyShell).joined(separator: " ")
        let readings: [(what: String, read: [String])] = try await awayFromTheTests {
            var readings: [(what: String, read: [String])] = []
            for shell in Self.shellsHere {
                for command in [line, "exec " + shell + " -c " + Shell.quoteAnyShell(line)] {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-c", command]
                    process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory(), "LANG": "en_US.UTF-8"]
                    process.standardInput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    let out = Pipe()
                    process.standardOutput = out
                    process.qualityOfService = .utility
                    try process.run()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    var read = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
                    if read.last == "" { read.removeLast() }
                    readings.append(("\(shell), \(command == line ? "quoted once" : "quoted twice")", read))
                }
            }
            return readings
        }
        for reading in readings { #expect(reading.read == words, "\(reading.what)") }
        #expect(readings.count == 2 * Self.shellsHere.count)
        print("D32 quoting: read back by \(Self.shellsHere.joined(separator: " "))")
        // a plain word stays as it is, as with the POSIX quoting
        #expect(Shell.quoteAnyShell("plain-word_1.2/x:y,z@h+i") == "plain-word_1.2/x:y,z@h+i")
        // except one with a percent sign: fish puts its own process id for a bare %self
        #expect(Shell.quoteAnyShell("%self") == "'%self'")
        #expect(Shell.quoteAnyShell("50%") == "'50%'")
        #expect(Shell.quoteAnyShell("it's") == #"'it'"'"'s'"#)
        #expect(Shell.quoteAnyShell(#"end\"#) == #"'end'\\"#)
        // and is made of nothing but plain text in single quotes, an apostrophe in double quotes, and a
        // backslash before a backslash
        let pieces = try NSRegularExpression(pattern: #"^(?:'[^'\\]*'|"'"|\\\\)+$"#)
        for word in words {
            let quoted = Shell.quoteAnyShell(word)
            #expect(quoted == word || pieces.firstMatch(in: quoted, range: NSRange(quoted.startIndex..., in: quoted)) != nil, "\(word)")
        }
    }

    /// zsh with MAGIC_EQUAL_SUBST on expands what follows an equals sign in a bare word, as it does in an
    /// assignment: x==sh becomes x= and the path of sh. Through one, two and three levels of quoting the
    /// word must come back as it was, and a pane must start in a folder of that name on a host whose login
    /// shell is such a zsh.
    @Test func aZshThatExpandsAfterAnEqualsSignReadsTheWordsBack() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let words = ["x==sh", "a=b", "k==", "DOJO_PANE=claude-1", "=sh", "plain"]
        let line = "/usr/bin/printf '%s\\0' " + words.map(Shell.quoteAnyShell).joined(separator: " ")
        let zsh = "exec /bin/zsh -f -o MAGIC_EQUAL_SUBST -c "
        let levels = [line, zsh + Shell.quoteAnyShell(line), zsh + Shell.quoteAnyShell(zsh + Shell.quoteAnyShell(line))]
        let readings: [[String]] = try await awayFromTheTests {
            try levels.map { command in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-f", "-o", "MAGIC_EQUAL_SUBST", "-c", command]
                process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
                process.standardInput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                let out = Pipe()
                process.standardOutput = out
                process.qualityOfService = .utility
                try process.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var read = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
                if read.last == "" { read.removeLast() }
                return read
            }
        }
        for (level, read) in readings.enumerated() { #expect(read == words, "quoted \(level + 1) times") }
        // an equals sign anywhere and the word is quoted
        #expect(Shell.quoteAnyShell("x==sh") == "'x==sh'")
        #expect(Shell.quoteAnyShell("DOJO_PANE=claude-1") == "'DOJO_PANE=claude-1'")

        // the whole way: such a zsh as the host's login shell and as this Mac's, a folder named x==sh
        let host = try Host()
        let magic = host.root.appendingPathComponent("zsh-magic-equal")
        try host.script(magic, "exec /bin/zsh -o MAGIC_EQUAL_SUBST \"$@\"")
        let runs: [(what: String, before: Seen?, after: Seen?)] = try await awayFromTheTests {
            try [(magic.path, "/bin/sh"), ("/bin/sh", magic.path)].flatMap { local, remote in
                try Self.kinds.map { kind in
                    ("\(kind), local \(local.hasSuffix("equal") ? "zsh with the option" : local), remote \(remote.hasSuffix("equal") ? "zsh with the option" : remote)",
                     try host.run(host.command(kind: kind, folder: "x==sh", main: true), local: local, remote: remote),
                     try host.run(host.command(kind: kind, folder: "x==sh", main: false), local: local, remote: remote))
                }
            }
        }
        for run in runs {
            let seen = try #require(run.after, "\(run.what): the harness did not start")
            #expect(host.same(seen.folder, host.path(of: "x==sh")), "\(run.what)")
            if let before = run.before { #expect(run.after == before, "\(run.what)") }
        }
    }

    /// The readers themselves: where fish and sh agree, and the two places where they part.
    @Test func theReadersSplitAsTheirShellsDo() {
        #expect(Fish.words("echo 'a b' c") == ["echo", "a b", "c"])
        #expect(Posix.words("echo 'a b' c") == ["echo", "a b", "c"])
        // an apostrophe between two quoted parts, written either way, is read alike by both
        for line in [#"echo 'it'\''s'"#, #"echo 'it'"'"'s'"#] {
            #expect(Fish.words(line) == ["echo", "it's"])
            #expect(Posix.words(line) == ["echo", "it's"])
        }
        // a backslash outside quotes is one backslash to both
        #expect(Fish.words(#"echo 'a'\\'b'"#) == ["echo", #"a\b"#])
        #expect(Posix.words(#"echo 'a'\\'b'"#) == ["echo", #"a\b"#])
        // a quoted word that ends in a backslash: sh closes the quote there, fish does not
        #expect(Posix.words(#"cd '/srv/end\' next"#) == ["cd", #"/srv/end\"#, "next"])
        #expect(Fish.words(#"cd '/srv/end\' next"#) == nil)
        // two backslashes inside single quotes are two to sh and one to fish
        #expect(Posix.words(#"echo 'a\\b'"#) == ["echo", #"a\\b"#])
        #expect(Fish.words(#"echo 'a\\b'"#) == ["echo", #"a\b"#])
        // what fish 3.7 said of the first command, for the very reason it gave
        let inner = "cd " + Shell.quote("/srv/it's here") + " && exec cat"
        #expect(Fish.words(#"exec "$SHELL" -l -i -c "# + Shell.quote(Shell.quote(inner))) != Posix.words(#"exec "$SHELL" -l -i -c "# + Shell.quote(Shell.quote(inner))))
        #expect(Fish.words("a && b") == ["a", "&&", "b"])
        #expect(Posix.words("a < b") == nil)
        // a backslash before a line break inside double quotes goes with the break, in both
        #expect(Fish.words("echo \"a\\\nb\"") == ["echo", "ab"])
        #expect(Posix.words("echo \"a\\\nb\"") == ["echo", "ab"])
        // and stays, with the break, inside single quotes
        #expect(Fish.words("echo 'a\\\nb'") == ["echo", "a\\\nb"])
        // a combining mark right after a quote is text, not part of the quote
        #expect(Fish.words("echo " + Shell.quoteAnyShell("\u{0301}")) == ["echo", "\u{0301}"])
        #expect(Posix.words("echo '\u{0301}x' y") == ["echo", "\u{0301}x", "y"])
        // the bare word %self is fish's own process id to fish, and itself to sh
        #expect(Posix.words("cd %self") == ["cd", "%self"])
        #expect(Fish.words("cd %self") == ["cd", Fish.ownProcessId])
        #expect(Fish.words("cd %self/x") == ["cd", "%self/x"])
        #expect(Fish.words("cd '%self'") == ["cd", "%self"])
        #expect(Fish.words("cd /srv/%self") == ["cd", "/srv/%self"])
    }
}

/// One of these tests runs its shells at a time, and the shells run at a low priority (`Process`'s quality of
/// service), so that a machine with few cores is not filled by them while other tests wait on a clock.
private let shellRuns = DispatchSemaphore(value: 1)

/// Runs work that waits on other programs away from the threads the tests share. A test that waits there
/// for a shell to end holds up every test that awaits something; nine of them at once starved a timing
/// test elsewhere in the suite, and two at once still slowed another on a hosted runner with three cores.
func awayFromTheTests<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            shellRuns.wait()
            defer { shellRuns.signal() }
            continuation.resume(with: Result { try work() })
        }
    }
}

/// How a shell splits a command line into words, as far as quoting goes; variables are left as written. Nil
/// when a quote is left open or a redirection, pipe, separator or lone `&` stands outside quotes, where the
/// shell would stop with an error or run something other than one command line of words. `&&` is a word.
/// A backslash before a line break is a continuation and goes with the break, outside quotes and inside
/// double quotes. The line is read scalar by scalar, as a shell reads it: a combining mark after a quote
/// belongs to the text, not to the quote. Each word comes with whether any of it was quoted or escaped.
private func splitWords(_ line: String, single: (Unicode.Scalar) -> Bool, double: (Unicode.Scalar) -> Bool) -> [(text: String, bare: Bool)]? {
    var words: [(text: String, bare: Bool)] = []
    var word = String.UnicodeScalarView()
    var inWord = false
    var bare = true
    var scalars = Array(line.unicodeScalars)[...]
    func end() {
        if inWord { words.append((String(word), bare)) }
        word = String.UnicodeScalarView()
        inWord = false
        bare = true
    }
    while let c = scalars.popFirst() {
        switch c {
        case " ", "\t":
            end()
        case "'":
            inWord = true
            bare = false
            var closed = false
            while let q = scalars.popFirst() {
                if q == "'" { closed = true; break }
                if q == "\\", let next = scalars.first, single(next) { word.append(scalars.removeFirst()) } else { word.append(q) }
            }
            guard closed else { return nil }
        case "\"":
            inWord = true
            bare = false
            var closed = false
            while let q = scalars.popFirst() {
                if q == "\"" { closed = true; break }
                if q == "\\", scalars.first == "\n" { scalars.removeFirst(); continue }
                if q == "\\", let next = scalars.first, double(next) { word.append(scalars.removeFirst()) } else { word.append(q) }
            }
            guard closed else { return nil }
        case "\\":
            guard let next = scalars.popFirst() else { return nil }
            if next == "\n" { continue }
            inWord = true
            bare = false
            word.append(next)
        case "&":
            guard scalars.first == "&" else { return nil }
            scalars.removeFirst()
            end()
            words.append(("&&", true))
        case "<", ">", "|", ";", "(", ")":
            return nil
        default:
            inWord = true
            word.append(c)
        }
    }
    end()
    return words
}

/// fish: inside single quotes a backslash escapes a backslash or an apostrophe and nothing else; inside
/// double quotes it escapes a backslash, a double quote or a dollar sign. The bare word `%self` gets fish's
/// own process id in its place, which no other shell here does. Seen with fish 4.9.3 on the hosted runner:
/// `%self` came back as a number, `%self/x` as itself.
enum Fish {
    static let ownProcessId = "<fish's own process id>"

    static func words(_ line: String) -> [String]? {
        splitWords(line, single: { $0 == "'" || $0 == "\\" }, double: { $0 == "\"" || $0 == "\\" || $0 == "$" })?.map { word in
            word.bare && word.text == "%self" ? ownProcessId : word.text
        }
    }
}

/// sh and its kin: nothing is special inside single quotes; inside double quotes a backslash escapes a
/// backslash, a double quote, a dollar sign or a backtick.
enum Posix {
    static func words(_ line: String) -> [String]? {
        splitWords(line, single: { _ in false }, double: { $0 == "\"" || $0 == "\\" || $0 == "$" || $0 == "`" })?.map(\.text)
    }
}

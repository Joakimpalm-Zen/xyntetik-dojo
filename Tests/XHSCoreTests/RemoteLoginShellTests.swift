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
    struct Seen: Equatable {
        let folder: String
        let argv: [String]
        let environment: [String]
    }

    /// A Mac and a host in one temporary folder: a home for each, folders to start in on the host, a stand-in
    /// for ssh and sshd, and stand-ins for the harness and for Runner's start script.
    final class Host {
        static let folderNames = ["plain", "two words", "it's", "end\\", "répo"]

        let fm = FileManager.default
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
        /// it, or as main builds it. Main's is put together here from the parts main's `Launcher.plan` uses
        /// (`harnessWords`, `Shell.line`, `Shell.quote`, `Shell.homeQuoted`, `sshWords`), in main's order.
        func command(kind: HarnessKind, folder: String?, main: Bool) -> String {
            let directory = folder.map { path(of: $0) }
            let forward: Int? = kind == .runner ? 18081 : nil
            guard main else {
                return Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                     runnerModel: nil, loginShell: "/bin/zsh", directory: directory, remotePort: 50001,
                                     runnerForward: forward).args[3]
            }
            var assignments = ["DOJO_PANE=\(kind)-1", "DOJO_PORT=50001", "DOJO_TOKEN=tok"]
            if kind == .runner { assignments += ["DOJO_RUNNER_PORT=\(Launcher.remoteRunnerPort)", "DOJO_RUNNER_TRAY=off"] }
            let harness = Launcher.harnessWords(kind: kind, paneName: "\(kind)-1", port: 50001, runnerModel: nil)
            let words: [ShellWord] = [.literal("env")] + assignments.map { ShellWord.literal($0) }
                + [.raw(#"PATH="$HOME/.dojo/bin:$PATH""#)] + harness
            let inner = (directory.map { "cd " + Shell.homeQuoted($0) + " && " } ?? "") + "exec " + Shell.line(words)
            let remote = #"exec "$SHELL" -l -i -c "# + Shell.quote(inner)
            return "exec " + Shell.line(Launcher.sshWords(host: "user@box", port: 7788, remotePort: 50001,
                                                          remoteCommand: remote, runnerForward: forward))
        }

        /// Runs the command as the app does: `local` reads it as a login shell, the stand-in ssh hands the
        /// remote command to `remote`, the host's login shell. Nil when the stand-in harness never started.
        func run(_ command: String, local: String, remote: String, remotePath: String = "/usr/bin:/bin",
                 extra: [String: String] = [:]) throws -> Seen? {
            for part in ["folder", "argv", "env"] { try? fm.removeItem(atPath: seen.path + "." + part) }
            guard command.hasPrefix("exec ssh ") else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: local)
            process.arguments = ["-l", "-i", "-c", "exec " + sshStandIn.path + " " + String(command.dropFirst("exec ssh ".count))]
            var environment = ["HOME": localHome.path, "PATH": "/usr/bin:/bin", "SHELL": local, "LANG": "en_US.UTF-8",
                               "DOJO_TEST_REMOTE_HOME": remoteHome.path, "DOJO_TEST_REMOTE_SHELL": remote,
                               "DOJO_TEST_REMOTE_PATH": remotePath, "DOJO_TEST_SEEN": seen.path]
            for (key, value) in extra { environment[key] = value }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let stuck = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: stuck)
            process.waitUntilExit()
            stuck.cancel()
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

    static let kinds: [HarnessKind] = [.claude, .runner]
    static let folders: [String?] = [nil] + Host.folderNames.map { Optional($0) }

    /// The differential. For each shell as this Mac's login shell and as the host's, each kind of pane and
    /// each folder: what main's command reaches, the new command reaches the same way.
    @Test(arguments: stages)
    func whatReachesTheHarnessOnMainReachesItTheSameWay(stage: Stage) throws {
        let host = try Host()
        var onMain = 0
        for kind in Self.kinds {
            for folder in Self.folders {
                let what = "\(kind), folder \(folder ?? "none"), \(stage)"
                let before = try host.run(host.command(kind: kind, folder: folder, main: true), local: stage.local, remote: stage.remote)
                let after = try host.run(host.command(kind: kind, folder: folder, main: false), local: stage.local, remote: stage.remote)
                if let before {
                    onMain += 1
                    #expect(after?.folder == before.folder, "\(what)")
                    #expect(after?.argv == before.argv, "\(what)")
                    #expect(after?.environment == before.environment, "\(what)")
                    // the host's zsh ran its directory hook on main, so the comparison covers it
                    if stage.remote == "/bin/zsh", folder != nil {
                        #expect(before.environment.contains { $0.hasPrefix("DOJO_TEST_HOOK=") }, "\(what)")
                    }
                }
                // And the new command on its own terms, which is all there is to go by where main fails:
                // the harness starts, in the folder asked for (the home when none is), with what it is given.
                let seen = try #require(after, "\(what): the harness did not start")
                #expect(host.same(seen.folder, host.path(of: folder)), "\(what)")
                if kind == .claude {
                    let prompt = seen.argv.firstIndex(of: "--append-system-prompt").map { seen.argv[$0 + 1] }
                    #expect(prompt == PeerRule.launchPrompt(paneName: "claude-1"), "\(what)")
                    #expect(seen.environment.contains("DOJO_TOKEN=tok") && seen.environment.contains("DOJO_PORT=50001"), "\(what)")
                } else {
                    #expect(seen.argv.isEmpty && seen.environment.contains("DOJO_RUNNER_TRAY=off"), "\(what)")
                }
            }
        }
        print("D32 differential, \(stage): main's command reached the harness in \(onMain) of \(Self.kinds.count * Self.folders.count) cases")
        // Without a case that works on main the comparison would say nothing.
        if !stage.hasFish { #expect(onMain > 0, "\(stage)") }
    }

    /// A directory hook of the login shell (zsh's chpwd) runs when the pane changes into its folder, and
    /// what it exports reaches the harness: here the harness is found only through the PATH the hook sets.
    @Test func aDirectoryHookOfTheLoginShellStillRuns() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/zsh") else { return }
        let host = try Host(harnessInToolsOf: "plain")
        try Data("chpwd() { export DOJO_TEST_HOOK=\"$PWD\"; export PATH=\"$PWD/tools:$PATH\" }\n".utf8)
            .write(to: host.remoteHome.appendingPathComponent(".zshrc"))
        let before = try #require(try host.run(host.command(kind: .claude, folder: "plain", main: true), local: "/bin/sh", remote: "/bin/zsh"),
                                  "main's command must reach the harness through the hook for this test to say anything")
        #expect(before.environment.contains { $0.hasPrefix("DOJO_TEST_HOOK=") })
        let after = try host.run(host.command(kind: .claude, folder: "plain", main: false), local: "/bin/sh", remote: "/bin/zsh")
        #expect(after == before)
    }

    /// A host with nothing on its PATH but sh and env, and one that also has a python3 whose output is ASCII
    /// only: main's command needs no tool to get the harness line across, so neither may the new one.
    @Test func aHostWithNoToolsBesideShAndEnvStartsAsOnMain() throws {
        let host = try Host()
        let bin = host.root.appendingPathComponent("bare-bin")
        try host.fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try host.fm.createSymbolicLink(atPath: bin.appendingPathComponent("sh").path, withDestinationPath: "/bin/sh")
        try host.fm.createSymbolicLink(atPath: bin.appendingPathComponent("env").path, withDestinationPath: "/usr/bin/env")
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { host.fm.isExecutableFile(atPath: $0) }
        for withPython in [false, true] {
            var extra: [String: String] = [:]
            if withPython {
                guard let python else { continue }
                try host.script(bin.appendingPathComponent("python3"), "exec \(python) \"$@\"")
                extra["PYTHONIOENCODING"] = "ascii"
            }
            for folder in ["plain", "répo"] {
                let what = "folder \(folder), python3 \(withPython ? "with ASCII output" : "absent")"
                let before = try #require(try host.run(host.command(kind: .claude, folder: folder, main: true), local: "/bin/sh",
                                                       remote: host.plainLogin.path, remotePath: bin.path, extra: extra),
                                          "\(what): main's command must reach the harness for this test to say anything")
                let after = try host.run(host.command(kind: .claude, folder: folder, main: false), local: "/bin/sh",
                                         remote: host.plainLogin.path, remotePath: bin.path, extra: extra)
                #expect(after == before, "\(what)")
            }
        }
    }

    /// With no fish on the machine its reading rule stands in for it: the command at each of the three levels
    /// must split into the same words for fish as for sh, for every kind of pane and awkward folder names.
    @Test func everyLevelSplitsTheSameForFishAsForSh() throws {
        let folders: [String?] = [nil, "/srv/plain", "/srv/two words", "/srv/it's", "/srv/end\\", "/srv/a\\\\b", "/srv/répo", "~/my repo"]
        for kind in [HarnessKind.claude, .codex, .pi, .runner, .shell] {
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
    }
}

/// How a shell splits a command line into words, as far as quoting goes; variables are left as written. Nil
/// when a quote is left open or a redirection, pipe, separator or lone `&` stands outside quotes, where the
/// shell would stop with an error or run something other than one command line of words. `&&` is a word.
private func splitWords(_ line: String, single: (Character) -> Bool, double: (Character) -> Bool) -> [String]? {
    var words: [String] = []
    var word = ""
    var inWord = false
    var chars = Array(line)[...]
    func end() { if inWord { words.append(word); word = ""; inWord = false } }
    while let c = chars.popFirst() {
        switch c {
        case " ", "\t":
            end()
        case "'":
            inWord = true
            var closed = false
            while let q = chars.popFirst() {
                if q == "'" { closed = true; break }
                if q == "\\", let next = chars.first, single(next) { word.append(chars.removeFirst()) } else { word.append(q) }
            }
            guard closed else { return nil }
        case "\"":
            inWord = true
            var closed = false
            while let q = chars.popFirst() {
                if q == "\"" { closed = true; break }
                if q == "\\", let next = chars.first, double(next) { word.append(chars.removeFirst()) } else { word.append(q) }
            }
            guard closed else { return nil }
        case "\\":
            guard let next = chars.popFirst() else { return nil }
            inWord = true
            word.append(next)
        case "&":
            guard chars.first == "&" else { return nil }
            chars.removeFirst()
            end()
            words.append("&&")
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
/// double quotes it escapes a backslash, a double quote or a dollar sign.
enum Fish {
    static func words(_ line: String) -> [String]? {
        splitWords(line, single: { $0 == "'" || $0 == "\\" }, double: { $0 == "\"" || $0 == "\\" || $0 == "$" })
    }
}

/// sh and its kin: nothing is special inside single quotes; inside double quotes a backslash escapes a
/// backslash, a double quote, a dollar sign or a backtick.
enum Posix {
    static func words(_ line: String) -> [String]? {
        splitWords(line, single: { _ in false }, double: { $0 == "\"" || $0 == "\\" || $0 == "$" || $0 == "`" })
    }
}

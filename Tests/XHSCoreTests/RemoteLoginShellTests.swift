import Foundation
import Testing
@testable import XHSCore

/// D32: sshd hands the remote command to the account's login shell, and that shell need not be a POSIX one.
/// fish reads a backslash before an apostrophe inside single quotes as an escape, and two backslashes there as
/// one, where a POSIX shell reads both as written. So nothing a login shell reads may hold a backslash inside
/// single quotes: not the command ssh carries, and not the command the login shell is then started with. The
/// harness line itself, which is quoted for sh, is read by sh.
///
/// These tests run the command for real, as sshd would, against a stand-in host: a home folder, a folder to
/// start in whose name holds an apostrophe and ends in a backslash, a stand-in `claude` that writes down where
/// it started and what it got, and a `bin` that holds exactly the tools a test gives the host.
@Suite struct RemoteLoginShellTests {
    final class Host {
        let fm = FileManager.default
        let home: URL
        let folder: URL
        /// The only folder on the PATH, unless a test adds another.
        let bin: URL
        /// A folder only the stand-in login shell puts on the PATH, as a login profile would.
        let profileBin: URL
        let record: URL
        let loginArgs: URL
        /// A login shell that reads no profile: it writes down what it was started with, puts `profileBin`
        /// on the PATH when the test asks, and has sh run its command.
        let login: URL

        init() throws {
            home = fm.temporaryDirectory.appendingPathComponent("dojo-host-\(UUID().uuidString)")
            folder = home.appendingPathComponent("it's end\\")
            bin = home.appendingPathComponent("bin")
            profileBin = home.appendingPathComponent("profile-bin")
            record = home.appendingPathComponent("started")
            loginArgs = home.appendingPathComponent("login-args")
            login = home.appendingPathComponent("login-shell")
            for dir in [folder, bin, profileBin, home.appendingPathComponent(".dojo/bin")] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try script(home.appendingPathComponent(".dojo/bin/claude"),
                       "{ pwd; for a in \"$@\"; do printf '%s\\0' \"$a\"; done; } > \"$DOJO_TEST_RECORD\"")
            try script(login, """
                for a in "$@"; do printf '%s\\0' "$a"; done > "$DOJO_TEST_LOGIN_ARGS"
                if [ -n "$DOJO_TEST_PROFILE" ]; then PATH="$DOJO_TEST_PROFILE:$PATH"; export PATH; fi
                exec /bin/sh -c "$4"
                """)
            try link("sh", to: "/bin/sh")
            try link("env", to: "/usr/bin/env")
        }

        deinit { try? fm.removeItem(at: home) }

        func script(_ url: URL, _ body: String) throws {
            try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func link(_ name: String, to path: String, in dir: URL? = nil) throws {
            try fm.createSymbolicLink(atPath: (dir ?? bin).appendingPathComponent(name).path, withDestinationPath: path)
        }

        /// The command ssh hands this host for a Claude pane that starts in `folder`.
        var remote: String {
            let plan = Launcher.plan(kind: .claude, paneName: "claude-1", host: "user@box", port: 7788, token: "tok",
                                     runnerModel: nil, loginShell: "/bin/zsh", directory: folder.path, remotePort: 50001)
            return shellArgs(plan.args[3]).last ?? ""
        }

        /// Runs the command as sshd does: the shell that takes it first gets it with -c. `login` is the
        /// account's login shell; `path` is the PATH before any profile, this host's `bin` unless given.
        @discardableResult
        func run(first: String = "/bin/sh", flags: [String] = [], login: String? = nil, path: String? = nil,
                 profile: Bool = false) throws -> (status: Int32, errors: String) {
            try? fm.removeItem(at: record)
            try? fm.removeItem(at: loginArgs)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: first)
            process.arguments = flags + ["-c", remote]
            var env = ["HOME": home.path, "PATH": path ?? bin.path, "SHELL": login ?? self.login.path,
                       "DOJO_TEST_RECORD": record.path, "DOJO_TEST_LOGIN_ARGS": loginArgs.path]
            if profile { env["DOJO_TEST_PROFILE"] = profileBin.path }
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let errors = Pipe()
            process.standardError = errors
            try process.run()
            let stuck = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: stuck)
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            stuck.cancel()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        }

        private func words(_ url: URL) -> [String] {
            var parts = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self).components(separatedBy: "\0")
            if parts.last == "" { parts.removeLast() }
            return parts
        }

        /// What the stand-in login shell was started with; empty when it was not started.
        var loginWords: [String] { words(loginArgs) }

        /// Where the stand-in harness started and what it got; nil when it did not start.
        var started: (folder: String, argv: [String])? {
            let text = String(decoding: (try? Data(contentsOf: record)) ?? Data(), as: UTF8.self)
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            guard lines.count == 2 else { return nil }
            var argv = lines[1].components(separatedBy: "\0")
            if argv.last == "" { argv.removeLast() }
            return (String(lines[0]), argv)
        }

        /// The harness started in the folder, with its settings and its prompt whole.
        func startedWhole() -> Bool {
            guard let started = self.started,
                  URL(fileURLWithPath: started.folder).resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
                  let settings = started.argv.firstIndex(of: "--settings"),
                  (try? JSONSerialization.jsonObject(with: Data(started.argv[settings + 1].utf8))) != nil,
                  let prompt = started.argv.firstIndex(of: "--append-system-prompt") else { return false }
            return started.argv[prompt + 1] == PeerRule.launchPrompt(paneName: "claude-1")
        }
    }

    static let fishPaths = ["/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"]

    /// What ssh carries is read first by the login shell, and what the login shell is then started with is
    /// read by it again: fish must read both as sh does, and the second must be nothing but a call of sh.
    @Test func fishReadsWhatALoginShellReadsAsShDoes() throws {
        let host = try Host()
        try host.link("base64", to: "/usr/bin/base64")
        let remote = host.remote
        // the command ssh carries
        let sh = shellArgs(remote)
        var fish = try #require(Fish.words(remote), "fish cannot read the command ssh carries")
        if fish.first == "exec" { fish.removeFirst() }
        #expect(fish.map { $0 == "$SHELL" ? "/bin/remote-shell" : $0 } == sh)
        // the command the login shell is started with
        try host.run()
        let login = host.loginWords
        #expect(Array(login.prefix(3)) == ["-l", "-i", "-c"])
        let command = try #require(login.count == 4 ? login[3] : nil, "the login shell was not started with one command")
        let words = try #require(Fish.words(command), "fish cannot read the command the login shell is started with")
        #expect(Array(words.prefix(3)) == ["exec", "sh", "-c"])
        #expect(words.count == 4)
        #expect(words == ["exec"] + shellArgs(command))
    }

    /// The rule the fake stands on: what fish 3.7 said of the first command, for the very reason it gave,
    /// and the two places where fish and sh part.
    @Test func theFakeFishReadsQuotesAsFishDoes() {
        let inner = "cd " + Shell.quote("/srv/it's here") + " && exec cat < file"
        #expect(Fish.words(#"exec "$SHELL" -l -i -c "# + Shell.quote(inner)) == nil)
        #expect(Fish.words("echo 'a b' c") == ["echo", "a b", "c"])
        #expect(Fish.words(#"echo 'it\'s' "x\"y""#) == ["echo", "it's", "x\"y"])
        // a quoted word that ends in a backslash: sh closes the quote there, fish does not
        #expect(Fish.words(#"cd '/srv/end\' next"#) == nil)
        // two backslashes inside single quotes are one to fish
        #expect(Fish.words(#"echo 'a\\b'"#) == ["echo", #"a\b"#])
        // an apostrophe between two quoted parts is read alike by both
        #expect(Fish.words(#"echo 'it'\''s'"#) == ["echo", "it's"])
    }

    /// Each shell this machine has takes the command first, as the account's login shell would: all of them
    /// start the login shell with the same words, and the harness starts.
    @Test func everyShellHereReadsTheCommandAlike() throws {
        let host = try Host()
        try host.link("base64", to: "/usr/bin/base64")
        try host.run()
        let expected = host.loginWords
        #expect(expected.count == 4)
        var ran: [String] = []
        var shells: [(path: String, flags: [String])] = [
            (path: "/bin/bash", flags: ["--noprofile", "--norc"]), (path: "/bin/zsh", flags: ["-f"]),
            (path: "/bin/csh", flags: ["-f"]), (path: "/bin/tcsh", flags: ["-f"]),
        ]
        for fish in Self.fishPaths { shells.append((path: fish, flags: ["--no-config"])) }
        for shell in shells where host.fm.isExecutableFile(atPath: shell.path) {
            try host.run(first: shell.path, flags: shell.flags)
            #expect(host.loginWords == expected, "\(shell.path)")
            #expect(host.startedWhole(), "\(shell.path)")
            ran.append(shell.path)
        }
        print("D32: shells that took the command first: \(ran.joined(separator: " "))")
        #expect(ran.count >= 2)
    }

    /// The whole way down with a real login shell: sh, bash, zsh, and fish where it is installed.
    @Test func theHarnessStartsUnderEveryLoginShellHere() throws {
        let host = try Host()
        var ran: [String] = []
        for login in ["/bin/sh", "/bin/bash", "/bin/zsh"] + Self.fishPaths where host.fm.isExecutableFile(atPath: login) {
            let result = try host.run(login: login, path: "/usr/bin:/bin")
            #expect(host.startedWhole(), "\(login): \(result.errors.suffix(300))")
            ran.append(login)
        }
        print("D32: login shells the harness started under: \(ran.joined(separator: " "))")
        #expect(ran.count >= 3)
    }

    /// A host whose base64 is on the PATH only once the login profile has run: the harness line must be
    /// decoded after the login shell has set the environment.
    @Test func aToolOnlyOnTheLoginProfilesPathIsFound() throws {
        let host = try Host()
        try host.link("base64", to: "/usr/bin/base64", in: host.profileBin)
        let result = try host.run(profile: true)
        #expect(host.startedWhole(), "\(result.errors.suffix(300))")
        #expect(result.status == 0)
    }

    /// base64 takes -d on Linux and on a current macOS, and only -D on macOS before 13.
    @Test func aBase64ThatTakesOneFlagOnlyDecodes() throws {
        for flag in ["-d", "-D"] {
            let host = try Host()
            try host.script(host.bin.appendingPathComponent("base64"),
                            "[ \"$1\" = \"\(flag)\" ] || { echo \"base64: invalid option -- $1\" >&2; exit 64; }\nexec /usr/bin/base64 -d")
            let result = try host.run()
            #expect(host.startedWhole(), "a base64 that takes only \(flag): \(result.errors.suffix(300))")
        }
    }

    /// A host with no base64 at all still has the python3 every harness host needs.
    @Test func aHostWithNoBase64DecodesWithPython() throws {
        let host = try Host()
        let python = try #require(["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
            .first { host.fm.isExecutableFile(atPath: $0) }, "no python3 on this machine")
        try host.script(host.bin.appendingPathComponent("python3"), "exec \(python) \"$@\"")
        let result = try host.run()
        #expect(host.startedWhole(), "\(result.errors.suffix(300))")
    }

    /// A host that can decode nothing: the pane ends, says what is missing, and does not report success.
    @Test func aHostThatCannotDecodeSaysSoAndFails() throws {
        let host = try Host()
        let result = try host.run()
        #expect(host.started == nil)
        #expect(result.status != 0)
        #expect(result.errors.contains("base64") && result.errors.contains("python3"), "\(result.errors.suffix(300))")
        #expect(result.errors.contains("Dojo"))
    }
}

/// How fish splits a command line into words, as far as quoting goes: inside single quotes a backslash
/// escapes a backslash or an apostrophe and nothing else; inside double quotes it escapes a backslash, a
/// double quote or a dollar sign; outside quotes it escapes the next character. Nil when a quote is left
/// open or a redirection, pipe or separator stands outside quotes, which is where fish stops with an error
/// or runs something other than one command. A variable is left as written.
enum Fish {
    static func words(_ line: String) -> [String]? {
        var words: [String] = []
        var word = ""
        var inWord = false
        var chars = Array(line)[...]
        while let c = chars.popFirst() {
            switch c {
            case " ", "\t":
                if inWord { words.append(word); word = ""; inWord = false }
            case "'":
                inWord = true
                var closed = false
                while let q = chars.popFirst() {
                    if q == "'" { closed = true; break }
                    if q == "\\", let next = chars.first, next == "'" || next == "\\" { word.append(chars.removeFirst()) } else { word.append(q) }
                }
                guard closed else { return nil }
            case "\"":
                inWord = true
                var closed = false
                while let q = chars.popFirst() {
                    if q == "\"" { closed = true; break }
                    if q == "\\", let next = chars.first, next == "\"" || next == "\\" || next == "$" { word.append(chars.removeFirst()) } else { word.append(q) }
                }
                guard closed else { return nil }
            case "\\":
                guard let next = chars.popFirst() else { return nil }
                inWord = true
                word.append(next)
            case "<", ">", "|", ";", "&", "(", ")":
                return nil
            default:
                inWord = true
                word.append(c)
            }
        }
        if inWord { words.append(word) }
        return words
    }
}

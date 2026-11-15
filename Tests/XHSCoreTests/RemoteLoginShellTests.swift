import Foundation
import Testing
@testable import XHSCore

/// D32: sshd hands the remote command to the account's login shell, and that shell need not be a POSIX one.
/// fish reads a backslash before an apostrophe inside single quotes as an escape, where a POSIX shell reads
/// the end of the quoted part, so a POSIX line quoted twice came apart there. The login shell now gets one
/// single-quoted word with no apostrophe and no backslash in it, which sh, bash, zsh, fish, csh and tcsh
/// all read the same way; the line itself travels inside it as base64 and sh on the host decodes it.
@Suite struct RemoteLoginShellTests {
    /// The command ssh hands to the host, for a pane whose folder and prompt both hold an apostrophe.
    private func remoteCommand(_ kind: HarnessKind) -> String {
        let plan = Launcher.plan(kind: kind, paneName: "\(kind)-1", host: "user@box", port: 7788, token: "tok",
                                 runnerModel: nil, loginShell: "/bin/zsh", directory: "/srv/it's here", remotePort: 50001,
                                 runnerForward: kind == .runner ? 18081 : nil)
        return shellArgs(plan.args[3]).last ?? ""
    }

    private static let kinds: [HarnessKind] = [.claude, .codex, .pi, .runner, .shell]

    @Test func theLoginShellGetsOneQuotedWordWithNothingToEscape() {
        for kind in Self.kinds {
            let remote = remoteCommand(kind)
            let head = "exec sh -c '"
            #expect(remote.hasPrefix(head) && remote.hasSuffix("'"), "\(kind): \(remote.prefix(60))")
            let script = remote.dropFirst(head.count).dropLast()
            #expect(!script.contains("'") && !script.contains("\\"), "\(kind)")
        }
    }

    @Test func fishReadsItAsFourWords() throws {
        for kind in Self.kinds {
            let words = try #require(Fish.words(remoteCommand(kind)), "\(kind): fish cannot read the command")
            #expect(words.count == 4, "\(kind)")
            #expect(Array(words.prefix(3)) == ["exec", "sh", "-c"], "\(kind)")
        }
    }

    /// The rule the fake stands on: what fish 3.7 said of the old command, for the very reason it gave.
    @Test func theFakeFishRefusesAPosixLineQuotedTwice() {
        let inner = "cd " + Shell.quote("/srv/it's here") + " && exec cat < file"
        #expect(Fish.words(#"exec "$SHELL" -l -i -c "# + Shell.quote(inner)) == nil)
        #expect(Fish.words("echo 'a b' c") == ["echo", "a b", "c"])
        #expect(Fish.words(#"echo 'it\'s' "x\"y""#) == ["echo", "it's", "x\"y"])
    }

    /// Each shell this machine has runs the command for real, with a login shell that only writes down what
    /// it was started with: the harness line arrives whole, whichever shell took the command first.
    @Test func everyShellHereHandsTheSameLineToTheLoginShell() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("dojo-login-shell-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let recorder = dir.appendingPathComponent("login-shell")
        let record = dir.appendingPathComponent("argv")
        try Data("#!/bin/sh\nfor a in \"$@\"; do printf '%s\\0' \"$a\"; done > \"$DOJO_TEST_RECORD\"\n".utf8).write(to: recorder)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recorder.path)

        let remote = remoteCommand(.claude)
        let line = try #require(Launcher.posixLoginLine(remote))
        let expected = shellArgs(line)
        #expect(Array(expected.prefix(4)) == ["/bin/remote-shell", "-l", "-i", "-c"])
        let inner = try #require(expected.last)
        #expect(inner.hasPrefix("cd '/srv/it'\\''s here' && exec env DOJO_PANE=claude-1 DOJO_PORT=50001 DOJO_TOKEN=tok "))

        let shells: [(path: String, flags: [String])] = [
            ("/bin/sh", []), ("/bin/bash", ["--noprofile", "--norc"]), ("/bin/zsh", ["-f"]), ("/bin/csh", ["-f"]),
            ("/bin/tcsh", ["-f"]), ("/usr/bin/fish", ["--no-config"]), ("/usr/local/bin/fish", ["--no-config"]),
            ("/opt/homebrew/bin/fish", ["--no-config"]),
        ]
        var ran = 0
        for shell in shells where fm.isExecutableFile(atPath: shell.path) {
            try? fm.removeItem(at: record)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shell.path)
            process.arguments = shell.flags + ["-c", remote]
            process.environment = ["HOME": dir.path, "PATH": "/usr/bin:/bin", "SHELL": recorder.path,
                                   "DOJO_TEST_RECORD": record.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            var argv = String(decoding: (try? Data(contentsOf: record)) ?? Data(), as: UTF8.self).components(separatedBy: "\0")
            if argv.last == "" { argv.removeLast() }
            #expect(argv == ["-l", "-i", "-c", inner], "\(shell.path)")
            ran += 1
        }
        #expect(ran >= 2, "at least sh and one other shell are on every Mac")
    }

    /// The whole way down, for each shell here taken as the account's login shell: sh decodes the line, the
    /// login shell runs it with -l -i -c, and a stand-in `claude` in ~/.dojo/bin writes down what it got.
    @Test func theHarnessStartsUnderEveryLoginShellHere() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("dojo-login-home-\(UUID().uuidString)")
        let folder = home.appendingPathComponent("it's here")
        let bin = home.appendingPathComponent(".dojo/bin")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }
        let record = home.appendingPathComponent("argv")
        let claude = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\n{ pwd; for a in \"$@\"; do printf '%s\\0' \"$a\"; done; } > \"$DOJO_TEST_RECORD\"\n".utf8).write(to: claude)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claude.path)
        let plan = Launcher.plan(kind: .claude, paneName: "claude-1", host: "user@box", port: 7788, token: "tok",
                                 runnerModel: nil, loginShell: "/bin/zsh", directory: folder.path, remotePort: 50001)
        let remote = try #require(shellArgs(plan.args[3]).last)

        var ran = 0
        for login in ["/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/fish", "/usr/local/bin/fish", "/opt/homebrew/bin/fish"]
        where fm.isExecutableFile(atPath: login) {
            try? fm.removeItem(at: record)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", remote]
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "SHELL": login, "DOJO_TEST_RECORD": record.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let stuck = DispatchWorkItem { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: stuck)
            process.waitUntilExit()
            stuck.cancel()
            let text = String(decoding: (try? Data(contentsOf: record)) ?? Data(), as: UTF8.self)
            let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            try #require(lines.count == 2, "\(login): the stand-in harness did not start")
            #expect(URL(fileURLWithPath: String(lines[0])).resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path, "\(login)")
            var argv = lines[1].components(separatedBy: "\0")
            if argv.last == "" { argv.removeLast() }
            let settings = try #require(argv.firstIndex(of: "--settings"), "\(login)")
            #expect((try? JSONSerialization.jsonObject(with: Data(argv[settings + 1].utf8))) != nil, "\(login)")
            let prompt = try #require(argv.firstIndex(of: "--append-system-prompt"), "\(login)")
            #expect(argv[prompt + 1] == PeerRule.launchPrompt(paneName: "claude-1"), "\(login)")
            ran += 1
        }
        #expect(ran >= 3)
    }

    @Test func aHostWhoseBase64TakesOnlyTheOldFlagStillDecodes() throws {
        // macOS before 13 has no -d: the script asks base64 first and falls back to -D.
        let script = try #require(Launcher.posixRemoteCommand(line: "echo hello").components(separatedBy: "'").dropFirst().first)
        #expect(script.hasPrefix("d=-d; echo QQ== | base64 -d >/dev/null 2>&1 || d=-D; "))
        #expect(script.hasSuffix(" | base64 $d)\""))
    }
}

/// How fish splits a command line into words, as far as quoting goes: inside single quotes a backslash
/// escapes a backslash or an apostrophe and nothing else; inside double quotes it escapes a backslash, a
/// double quote or a dollar sign; outside quotes it escapes the next character. Nil when a quote is left
/// open or a redirection, pipe or separator stands outside quotes, which is where fish stops with an error
/// or runs something other than one command.
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

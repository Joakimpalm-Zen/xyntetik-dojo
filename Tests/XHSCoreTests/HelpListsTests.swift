import Foundation
import Testing
@testable import XHSCore

/// D38: `make smoke` failed in an agy pane, and only there: "in a login shell contained false". agy's shell tool
/// runs commands on a terminal of its own, so Dojo started there has a controlling terminal, as it has in
/// Terminal.app and has not in a Claude pane's tool or on CI. `helpLists` started its login shell with
/// Foundation's Process, which puts the child in a process group of its own: a background group of that
/// terminal, where an interactive shell is stopped (SIGTTIN) until the time runs out. The shell it asks now runs
/// in a session of its own, with no controlling terminal, as a pane's harness does in the pane's own terminal.
@Suite struct HelpListsTests {
    @Test func theShellItAsksRunsInASessionOfItsOwnWithNoTerminal() async {
        // ps writes s in the state of a session leader, and ?? for no controlling terminal
        #expect(await Launcher.helpLists("session-leader", command: #"case $(ps -o stat= -p $$) in *s*) echo session-leader;; esac"#,
                                         loginShell: "/bin/sh"))
        #expect(await Launcher.helpLists("no-terminal", command: #"case $(ps -o tty= -p $$) in *"??"*) echo no-terminal;; esac"#,
                                         loginShell: "/bin/sh"))
    }

    /// As before: what the shell prints is what is asked about, and no answer in time is a no.
    @Test func itAnswersAsBefore() async {
        #expect(await Launcher.helpLists("--session-id", command: "printf '%s\\n' --session-id", loginShell: "/bin/sh"))
        #expect(!(await Launcher.helpLists("--session-id", command: "echo nothing of the kind", loginShell: "/bin/sh")))
        let start = Date()
        #expect(!(await Launcher.helpLists("late", command: "sleep 10; echo late", loginShell: "/bin/sh", timeout: 1)))
        #expect(Date().timeIntervalSince(start) < 5, "the time limit still holds")
        // the shell gets this process's environment, as it did
        setenv("DOJO_HELPLISTS_TEST", "carried", 1)
        #expect(await Launcher.helpLists("carried", command: #"echo "$DOJO_HELPLISTS_TEST""#, loginShell: "/bin/sh"))
        unsetenv("DOJO_HELPLISTS_TEST")
    }

    /// The real reason, where it happened: Dojo with a controlling terminal of its own, as when it is started
    /// from a terminal, and the owner's login shell, zsh, interactive. Under Foundation's Process the shell was
    /// in a background group of that terminal, stopped until the time ran out, and the answer was no. The
    /// check runs in a child process of its own, which takes a new terminal, so the tests' own run is not
    /// touched; zsh reads no profile of the owner's (ZDOTDIR, in that process only), and stops without one.
    @Test func anInteractiveZshAnswersWhereDojoHasATerminal() async {
        await #expect(processExitsWith: .success) {
            guard setsid() != -1 else { exit(2) }
            let master = posix_openpt(O_RDWR | O_NOCTTY)
            guard master >= 0, grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else { exit(3) }
            let terminal = open(name, O_RDWR)
            // TIOCSCTTY, _IO('t', 97), which Swift does not import: the terminal becomes this session's
            guard terminal >= 0, ioctl(terminal, UInt(0x2000_7461)) == 0, tcgetpgrp(terminal) == getpgrp() else { exit(4) }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("zdotdir-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            setenv("ZDOTDIR", folder.path, 1)
            let answer = await Launcher.helpLists("--session-id", command: "printf '%s\\n' --session-id", loginShell: "/bin/zsh",
                                                  timeout: 10)
            exit(answer ? 0 : 1)
        }
    }

    /// At the time limit the shell ends, and so does what it started (the second read of #114): SIGTERM to the
    /// shell alone ended neither a shell that ignores it, as an interactive one does, nor a program the shell
    /// left behind holding its output, which kept the pipe, the thread reading it and the shell's exit for as
    /// long as it ran. Each shell writes its own pid and the program's; both must be gone, the shell reaped.
    @Test func atTheTimeLimitTheShellAndWhatItStartedAreGone() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("helplists-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ways = ["ignores": #"trap "" TERM; echo $$ >> PIDS; sleep 30 & echo $! >> PIDS; wait"#,
                    "left": #"echo $$ >> PIDS; sleep 30 & echo $! >> PIDS"#]
        for (way, script) in ways {
            let pids = folder.appendingPathComponent(way).path
            let start = Date()
            #expect(!(await Launcher.helpLists("never", command: script.replacingOccurrences(of: "PIDS", with: Shell.quote(pids)),
                                               loginShell: "/bin/sh", timeout: 1)), "\(way)")
            #expect(Date().timeIntervalSince(start) < wellBeforeTheProgramWouldEnd, "\(way)")
            let written = (try? String(contentsOfFile: pids, encoding: .utf8)) ?? ""
            let started = written.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
            #expect(started.count == 2, "\(way): \(written.debugDescription)")
            // gone: no process has the pid, not even a zombie, which still answers kill(pid, 0)
            func gone(_ pid: pid_t) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }
            let until = Date().addingTimeInterval(5)
            while Date() < until, !started.allSatisfy(gone) { try await Task.sleep(nanoseconds: 50_000_000) }
            #expect(started.allSatisfy(gone), "\(way): \(started.map { "\($0) \(gone($0) ? "gone" : "still there")" })")
            for pid in started where !gone(pid) { kill(pid, SIGKILL) }
        }
    }

    /// When the program has ended, its pid stays its own until Detached reaps it (the second read of #114):
    /// the wait outside the lock reaped it before the lock said so, and a stop() in between signalled a pid
    /// that could be another program's by then. Here the moment is the one stop() could take: right after
    /// the wait saw the end, the pid is still the program's, a zombie. And it is reaped in the end.
    @Test func whenTheProgramEndsItsPidIsItsOwnUntilItIsReaped() async throws {
        let seen = Seen()
        let child = try #require(Launcher.Detached("/bin/sh", ["-c", "exit 3"], onExit: { pid in seen.note(kill(pid, 0) == 0) }))
        _ = child.output.readDataToEndOfFile()
        child.outputEnded()
        let until = Date().addingTimeInterval(5)
        while Date() < until, seen.stillItsOwn == nil || !(kill(child.pid, 0) == -1 && errno == ESRCH) {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(seen.stillItsOwn == true, "the pid was the program's when the wait saw it end")
        #expect(kill(child.pid, 0) == -1 && errno == ESRCH, "and it is reaped")
        child.stop()
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool?
        var stillItsOwn: Bool? { lock.lock(); defer { lock.unlock() }; return value }
        func note(_ stillItsOwn: Bool) { lock.lock(); value = stillItsOwn; lock.unlock() }
    }
}

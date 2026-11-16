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
}

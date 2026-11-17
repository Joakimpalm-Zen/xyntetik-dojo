import Foundation
import Testing
@testable import XHSCore

/// D38 follow-up: agy draws a fresh session from its cursor down, so a new pane had its composer near the top.
/// The pane starts agy from its foot: `Launcher.agyFootStart` prints the pane's rows less one as new lines,
/// read with `stty size` in the pane's own shell, and runs agy. Run for real here, in a pseudo-terminal of
/// 45 rows, with no terminal, and where stty gives nothing to go by: agy starts in every case.
@Suite struct AgyFootStartTests {
    /// The script, then a stand-in for agy that writes a mark: what the pane would see before agy draws.
    static func run(rows: Int?, path: String = "/usr/bin:/bin", agy: [String] = ["/usr/bin/printf", "AGY-STARTED"]) throws
        -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let command = ["/bin/sh", "-c", Launcher.agyFootStart, "sh"] + agy
        if let rows {
            // a pty of that size, as a pane's; python3 is on every test machine (the shim's tests need it)
            let harness = """
            import fcntl, os, pty, struct, sys, termios
            rows = int(sys.argv[1]); argv = sys.argv[2:]
            pid, fd = pty.fork()
            if pid == 0:
                fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, 80, 0, 0))
                os.execv(argv[0], argv)
            out = b""
            while True:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                out += data
            _, status = os.waitpid(pid, 0)
            sys.stdout.buffer.write(out)
            sys.exit(os.waitstatus_to_exitcode(status))
            """
            process.arguments = ["python3", "-c", harness, String(rows)] + command
        } else {
            process.arguments = command
            process.standardInput = FileHandle.nullDevice
        }
        process.environment = ["PATH": path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func aPaneOf45RowsGets44NewLinesAndThenAgy() throws {
        let (status, out) = try Self.run(rows: 45, path: "/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? ""))
        #expect(status == 0)
        #expect(out == String(repeating: "\r\n", count: 44) + "AGY-STARTED", "\(out.debugDescription)")
    }

    /// No terminal (stty has none to ask): no new lines, and agy starts as it did before.
    @Test func withNoTerminalAgyStartsAsBefore() throws {
        let (status, out) = try Self.run(rows: nil)
        #expect(status == 0)
        #expect(out == "AGY-STARTED")
    }

    /// No stty at all, or one that answers what is no size (a host where it fails another way): agy starts.
    @Test func withNoUsableSttyAgyStartsAsBefore() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("foot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // only the shell's own words on the PATH, and an empty folder: no stty
        let none = try Self.run(rows: 45, path: folder.path + ":" + Self.pythonFolder())
        #expect(none.status == 0)
        #expect(none.out.hasSuffix("AGY-STARTED"))
        #expect(!none.out.contains("\r\n"), "\(none.out.debugDescription)")
        for answer in ["stty: stdin isn't a terminal", "0 0", "45x80", "-1 80", ""] {
            let stty = folder.appendingPathComponent("stty")
            try "#!/bin/sh\necho '\(answer)'\n".write(to: stty, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stty.path)
            let odd = try Self.run(rows: 45, path: folder.path + ":" + Self.pythonFolder())
            #expect(odd.status == 0, "\(answer)")
            #expect(odd.out == "AGY-STARTED", "\(answer): \(odd.out.debugDescription)")
        }
    }

    /// The second read of #114: the script puts its own pid in DOJO_AGY_PID, and agy, run with exec, keeps
    /// that pid. So the variable names the pane's own agy, the one Dojo's plugin acts for, and not an agy the
    /// pane's agent runs under it, which inherits the variable with a pid of its own. With a terminal and
    /// without: the stand-in for agy says its own pid and the variable's.
    @Test func itTellsAgyItsOwnPid() throws {
        let says = ["/bin/sh", "-c", #"printf 'pid %s is %s' "$DOJO_AGY_PID" "$$""#]
        for rows in [45, nil] as [Int?] {
            let (status, out) = try Self.run(rows: rows, path: "/usr/bin:/bin:" + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
                                             agy: says)
            #expect(status == 0)
            let words = out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
            #expect(words.count == 4 && words[0] == "pid" && words[2] == "is" && Int32(words[1]) != nil && words[1] == words[3],
                    "\(String(describing: rows)): \(out.debugDescription)")
        }
    }

    /// The folder python3 is in, for the pty harness, without the system folders that hold stty.
    static func pythonFolder() -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let found = path.split(separator: ":").map(String.init).first {
            FileManager.default.isExecutableFile(atPath: $0 + "/python3") && !["/bin", "/usr/bin"].contains($0)
        }
        return found ?? "/usr/bin"
    }
}

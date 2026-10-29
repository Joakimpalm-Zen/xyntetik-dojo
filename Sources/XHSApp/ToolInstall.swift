import Foundation

/// Puts the shim and the pi extension in ~/.dojo and runs "dojo install" (the dojo command and the Codex entries).
enum ToolInstall {
    static let files = ["dojo-mcp.py", "dojo-pi.ts", "runner-start.sh"]

    /// Contents/Resources/tools in the app bundle, or tools/ in the source tree for `swift run`.
    static func sourceDirectory() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"),
           fm.fileExists(atPath: bundled.appendingPathComponent("dojo-mcp.py").path) {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools")
        return fm.fileExists(atPath: source.appendingPathComponent("dojo-mcp.py").path) ? source : nil
    }

    /// Returns a problem to show, or nil.
    static func run() -> String? {
        let fm = FileManager.default
        guard let source = sourceDirectory() else { return "The dojo tools were not found in the app bundle." }
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent(".dojo")
        let moved = moveOldHome(to: target)
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                let destination = target.appendingPathComponent(file)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source.appendingPathComponent(file), to: destination)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", target.appendingPathComponent("dojo-mcp.py").path, "install"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { return "dojo install failed; run python3 ~/.dojo/dojo-mcp.py install" }
            return moved
        } catch {
            return "Could not install the dojo tools in ~/.dojo: \(error.localizedDescription)"
        }
    }

    /// The folder was ~/.xhs until 2026-10-29: hosts, folders and Runner's files move over once. When
    /// ~/.dojo already exists (a smoke run made it), each entry that is not there yet moves on its own.
    /// Returns a problem to show, or nil; nothing here stops the install.
    static func moveOldHome(to target: URL) -> String? {
        let fm = FileManager.default
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent(".xhs")
        guard fm.fileExists(atPath: old.path) else { return nil }
        let stale = ["xhs-mcp.py", "xhs-pi.ts", "bin/xhs"]
        do {
            if !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: old, to: target)
            } else {
                for entry in try fm.contentsOfDirectory(atPath: old.path) where !stale.contains(entry) {
                    let destination = target.appendingPathComponent(entry)
                    if entry == "bin" {
                        // Runner's binary may live in bin; the old xhs link does not come along.
                        for inner in (try? fm.contentsOfDirectory(atPath: old.appendingPathComponent("bin").path)) ?? [] where inner != "xhs" {
                            let to = destination.appendingPathComponent(inner)
                            if !fm.fileExists(atPath: to.path) {
                                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                                try fm.moveItem(at: old.appendingPathComponent("bin/\(inner)"), to: to)
                            }
                        }
                    } else if !fm.fileExists(atPath: destination.path) {
                        try fm.moveItem(at: old.appendingPathComponent(entry), to: destination)
                    }
                }
                try fm.removeItem(at: old)
            }
            for name in stale { try? fm.removeItem(at: target.appendingPathComponent(name)) }
            return nil
        } catch {
            return "~/.xhs could not be moved to ~/.dojo: \(error.localizedDescription). Move what you want by hand."
        }
    }
}

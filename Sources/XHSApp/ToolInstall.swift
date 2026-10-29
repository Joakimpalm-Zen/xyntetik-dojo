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
        do {
            // The folder was ~/.xhs until 2026-10-29: hosts, folders and Runner's files move over once.
            let old = fm.homeDirectoryForCurrentUser.appendingPathComponent(".xhs")
            if !fm.fileExists(atPath: target.path), fm.fileExists(atPath: old.path) {
                try fm.moveItem(at: old, to: target)
                for stale in ["xhs-mcp.py", "xhs-pi.ts", "bin/xhs"] {
                    try? fm.removeItem(at: target.appendingPathComponent(stale))
                }
            }
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
            return process.terminationStatus == 0 ? nil : "dojo install failed; run python3 ~/.dojo/dojo-mcp.py install"
        } catch {
            return "Could not install the dojo tools in ~/.dojo: \(error.localizedDescription)"
        }
    }
}

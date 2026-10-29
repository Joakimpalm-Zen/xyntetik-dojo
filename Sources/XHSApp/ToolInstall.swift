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
    /// ~/.dojo already exists (a smoke run made it), the two are merged: what is missing on the new side
    /// moves, folder by folder; a file that exists on both sides stays where it was, and ~/.xhs is
    /// removed only when nothing is left in it. Returns a problem to show, or nil; nothing here stops
    /// the install.
    static func moveOldHome(to target: URL) -> String? {
        let fm = FileManager.default
        let old = fm.homeDirectoryForCurrentUser.appendingPathComponent(".xhs")
        guard fm.fileExists(atPath: old.path) else { return nil }
        let stale = ["xhs-mcp.py", "xhs-pi.ts", "bin/xhs"]
        do {
            for name in stale { try? fm.removeItem(at: old.appendingPathComponent(name)) }
            if !fm.fileExists(atPath: target.path) {
                try fm.moveItem(at: old, to: target)
                return nil
            }
            try merge(from: old, into: target)
            if try fm.contentsOfDirectory(atPath: old.path).isEmpty {
                try fm.removeItem(at: old)
                return nil
            }
            return "~/.xhs still holds files that ~/.dojo has too; the ones in ~/.dojo were kept. Merge or delete ~/.xhs by hand."
        } catch {
            return "~/.xhs could not be moved to ~/.dojo: \(error.localizedDescription). Move what you want by hand."
        }
    }

    /// Moves every entry of `from` that `into` lacks; descends into folders both have; leaves files both have.
    private static func merge(from: URL, into: URL) throws {
        let fm = FileManager.default
        for entry in try fm.contentsOfDirectory(atPath: from.path) {
            let source = from.appendingPathComponent(entry), destination = into.appendingPathComponent(entry)
            var sourceIsDir: ObjCBool = false, destinationIsDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &sourceIsDir)
            if !fm.fileExists(atPath: destination.path, isDirectory: &destinationIsDir) {
                try fm.moveItem(at: source, to: destination)
            } else if sourceIsDir.boolValue, destinationIsDir.boolValue {
                try merge(from: source, into: destination)
                if try fm.contentsOfDirectory(atPath: source.path).isEmpty { try fm.removeItem(at: source) }
            }
        }
    }
}

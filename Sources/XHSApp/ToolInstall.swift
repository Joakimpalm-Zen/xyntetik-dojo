import Foundation

/// Puts the shim and the pi extension in ~/.xhs and runs "xhs install" (the xhs command and the Codex entries).
enum ToolInstall {
    static let files = ["xhs-mcp.py", "xhs-pi.ts"]

    /// Contents/Resources/tools in the app bundle, or tools/ in the source tree for `swift run`.
    static func sourceDirectory() -> URL? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("tools"),
           fm.fileExists(atPath: bundled.appendingPathComponent("xhs-mcp.py").path) {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools")
        return fm.fileExists(atPath: source.appendingPathComponent("xhs-mcp.py").path) ? source : nil
    }

    /// Returns a problem to show, or nil.
    static func run() -> String? {
        let fm = FileManager.default
        guard let source = sourceDirectory() else { return "The xhs tools were not found in the app bundle." }
        let target = fm.homeDirectoryForCurrentUser.appendingPathComponent(".xhs")
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                let destination = target.appendingPathComponent(file)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: source.appendingPathComponent(file), to: destination)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", target.appendingPathComponent("xhs-mcp.py").path, "install"]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? nil : "xhs install failed; run python3 ~/.xhs/xhs-mcp.py install"
        } catch {
            return "Could not install the xhs tools in ~/.xhs: \(error.localizedDescription)"
        }
    }
}

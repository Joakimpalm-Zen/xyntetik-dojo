import Darwin
import Foundation

/// D15 (b): a program outside Dojo sending a line to a pane, off unless the owner sets it up.
///
/// It lets any program running as the owner type into an agent's pane, so it exists only while
/// `~/.dojo/outside` is there, a regular file of the owner's that no one else can write, as the relay's
/// config is. Then the app keeps a fresh token in `~/.dojo/outside-token` (0600, with the port) and the bus
/// takes `POST /outside/send` with it in `X-Dojo-Outside-Token`. Send only: it cannot list or read a
/// pane. Every line arrives as `[from: outside]`, whatever the caller says, goes through the same holds as
/// a pane's message, and is recorded; like any bus message it is never the owner's approval of anything.
/// Without the switch there is no token file and no route.
public enum Outside {
    /// The sender every outside line carries. No pane may take the name.
    public static let sender = "outside"
    /// Lines a minute, from all outside callers together.
    public static let perMinute = 30

    /// Nil when there is no switch; a failure when there is one that someone else could have made or changed.
    public static func switchState(_ url: URL) -> Checked<Bool>? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        if let why = Relay.unsafe(info, "the outside switch") { return .failure(why) }
        return .success(true)
    }

    /// Two tokens compared in time that does not depend on where they differ.
    static func same(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in x.indices { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}

/// The switch and the token file, kept in step: `refresh` reads the switch and writes or removes the token
/// file to match, so switching the route on or off takes effect within seconds, without a restart.
@MainActor
public final class OutsideRoute {
    public let switchFile: URL
    public let tokenFile: URL
    public let port: Int
    /// The token while the route is on, nil while it is off.
    public private(set) var token: String?
    /// Why a switch that is there does not count, for the owner.
    public private(set) var problem: String?

    public init(switchFile: URL, tokenFile: URL, port: Int) {
        self.switchFile = switchFile
        self.tokenFile = tokenFile
        self.port = port
    }

    public func refresh() {
        switch Outside.switchState(switchFile) {
        case .success?:
            problem = nil
            let current = token ?? Bus.newToken()
            if token == nil || !FileManager.default.fileExists(atPath: tokenFile.path) {
                token = write(current) ? current : nil
            }
        case .failure(let why)?:
            problem = why
            off()
        case nil:
            problem = nil
            off()
        }
    }

    /// At quit, and whenever the switch goes: no route, no token file.
    public func off() {
        token = nil
        try? FileManager.default.removeItem(at: tokenFile)
    }

    /// Atomic and 0600 from the first byte. False when it cannot be written: then the route stays off.
    private func write(_ token: String) -> Bool {
        let object: [String: Any] = ["port": port, "token": token]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        data.append(0x0A)
        let dir = tokenFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appendingPathComponent(".outside-\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return false }
        let ok = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) } == data.count
        close(fd)
        guard ok, rename(temp.path, tokenFile.path) == 0 else {
            unlink(temp.path)
            return false
        }
        return true
    }
}

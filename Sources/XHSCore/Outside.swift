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
    /// What a pane's send may carry and a line from outside may not: a typed message's kind and its fields.
    /// Refused when present at all, whatever the value, so a later meaning of either cannot come in this way.
    public static let paneOnly = ["type", "fields"]

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
            if token == nil || !tokenFileMatches(current) {
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

    private func tokenFileMatches(_ expectedToken: String) -> Bool {
        var info = stat()
        guard lstat(tokenFile.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_mode & 0o777) == 0o600,
              info.st_uid == getuid(),
              let data = FileManager.default.contents(atPath: tokenFile.path),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (object["port"] as? Int) == port,
              let onDisk = object["token"] as? String
        else { return false }
        return Outside.same(onDisk, expectedToken)
    }

    /// Atomic and 0600 from the first byte. False when it cannot be written: then the route stays off.
    private func write(_ token: String) -> Bool {
        let object: [String: Any] = ["port": port, "token": token]
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        data.append(0x0A)
        return SavedPanes.writePrivate(data, to: tokenFile, tempPrefix: "outside")
    }
}

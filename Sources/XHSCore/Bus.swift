import Foundation
import Security

/// What the bus needs from a terminal pane.
@MainActor
public protocol PaneIO: AnyObject {
    /// Writes bytes into the pane's pty as if typed.
    func write(_ bytes: [UInt8])
    /// The screen and scrollback as text, one line per row.
    func screenText() -> String
    /// The rows on screen right now, without the scrollback; what `tick` watches for change.
    func visibleText() -> String
    /// Whether the program in the pane turned on bracketed paste.
    var bracketedPasteEnabled: Bool { get }
}

/// The message bus: pane registry, per-pane state, queued messages and the four operations.
/// Every request carries a pane's token; the token tells the bus who is asking.
@MainActor
public final class Bus {
    /// Where the relay's config is, nil for none: see `Relay`.
    public var relayConfig: URL?
    private var relayRunning = false

    public struct Info: Equatable, Sendable {
        public let name: String
        public let kind: HarnessKind
        public let host: String
        public let state: PaneState
        public let queued: Int
        public let model: String
        /// The owner has unsent text in the pane; the bus holds its queue until that is sent or cleared.
        public let draft: Bool

        var json: [String: Any] {
            ["name": name, "kind": kind.rawValue, "host": host, "state": state.rawValue, "queued": queued, "model": model,
             "draft": draft]
        }
    }

    final class Pane {
        var name: String
        let kind: HarnessKind
        let host: String
        let token: String
        var model: String
        var state: PaneState
        /// Who sent what; the `[from: name]` line is built at delivery, so a renamed sender is named right.
        var queue: [(sender: Pane, text: String)] = []
        var lastOwnerInput: Date?
        /// The message text is in the composer and its Enter is still to come.
        var enterPending = false
        /// The owner may have unsent text in the composer: set by any key that can add text, cleared by
        /// Ctrl-C or by the harness reporting a submission that nothing was typed after.
        var hasDraft = false
        /// Text keys came after the last Enter: a submission hook arriving now is for an earlier prompt.
        var typedSinceSubmit = false
        /// The screen as last seen by `tick`, and since when it has looked like that.
        var screenHash = 0
        var quietSince: Date?
        /// A hook reported this turn running, and none has reported its end. The still-screen rule may have
        /// called the pane idle in the meantime; that leaves the turn open, so a late Stop still counts.
        var turnOpen = false
        /// The harness's session, to resume it. Never in what the bus tells other panes.
        var sessionId: String?
        /// Panes that asked to hear when this one next stops, and since when.
        var watchers: [(asker: Pane, since: Date)] = []
        weak var io: PaneIO?

        init(name: String, kind: HarnessKind, host: String, token: String, model: String, state: PaneState, io: PaneIO?) {
            self.name = name
            self.kind = kind
            self.host = host
            self.token = token
            self.model = model
            self.state = state
            self.io = io
        }
    }

    /// How long a request to hear about a pane lasts.
    public static let watchHours = 12
    public static let maxMessageLength = 16_000
    public static let maxReadLines = 500

    private var panes: [Pane] = []
    /// Called after any change a pane header shows.
    public var onChange: (() -> Void)?
    /// A pane's session id changed.
    public var onSession: (() -> Void)?
    /// A pane reported, through a hook, something the owner may want to know. See `Attention`.
    public var onAttention: ((String, Attention) -> Void)?
    /// Delay between typing a message and pressing Enter, so the harness sees the paste end first.
    public var submitDelay: TimeInterval = 0.15
    /// The bus does not type into a pane the owner typed into this recently.
    public var ownerQuietInterval: TimeInterval = 3
    /// A `running` pane whose screen has not changed for this long is idle again: its turn ended without
    /// a Stop hook (an API error, a lost hook). Every harness animates a spinner while it works.
    public var idleAfterQuiet: TimeInterval = 15
    /// A `starting` pane of a harness with an idle fingerprint is idle once its screen shows the fingerprint
    /// and has not changed for this long.
    public var readyAfterQuiet: TimeInterval = 3
    public var now: () -> Date = { Date() }
    /// Runs `work` after `delay` on the main queue; a test swaps it to fire by hand.
    public var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public init() {}

    // MARK: registry

    public var names: [String] { panes.map(\.name) }
    public var all: [Info] { panes.map(info) }

    public func info(_ name: String) -> Info? { pane(named: name).map(info) }

    /// Registers a pane and returns its token. Harness panes start as `starting` and change state from hooks.
    @discardableResult
    public func add(name: String, kind: HarnessKind, host: String = "", model: String = "", io: PaneIO? = nil) -> String {
        precondition(pane(named: name) == nil, "duplicate pane name \(name)")
        let token = Bus.newToken()
        let initial: PaneState = kind == .shell ? .idle : .starting
        panes.append(Pane(name: name, kind: kind, host: host, token: token, model: model, state: initial, io: io))
        onChange?()
        return token
    }

    public func attach(_ io: PaneIO, to name: String) {
        pane(named: name)?.io = io
    }

    /// Gives a pane a new name. Its token, state and queue stay; from now on its messages carry the new name
    /// and others reach it by the new name only. Returns a reason when the name is not usable.
    public func rename(_ name: String, to new: String) -> String? {
        guard let p = pane(named: name) else { return "no pane named '\(name)'" }
        guard PaneNames.isValid(new) else { return PaneNames.rule }
        if new == name { return nil }
        guard pane(named: new) == nil else { return "\(new) is already open." }
        p.name = new
        onChange?()
        return nil
    }

    public func remove(_ name: String) {
        let gone = pane(named: name)
        panes.removeAll { $0.name == name }
        for p in panes { p.watchers.removeAll { $0.asker === gone } }
        if let gone { tellWatchers(of: gone, "\(gone.name) was closed.") }
        onChange?()
    }

    public func setState(_ name: String, _ state: PaneState) {
        guard let p = pane(named: name), p.state != state else { return }
        p.state = state
        onChange?()
        flush(p)
        switch state {
        // A hook's end of a turn has told them already. What is left is the still-screen rule, and the line
        // says so while a hook-reported turn is open: the bus does not know that turn ended.
        case .idle:
            tellWatchers(of: p, p.turnOpen ? "\(p.name) looks idle: its screen has been still for \(Int(idleAfterQuiet)) seconds, "
                + "but no hook has reported the end of its turn." : "\(p.name) is idle.")
        case .prompt: tellWatchers(of: p, "\(p.name) is at a prompt.")
        case .exited: tellWatchers(of: p, "\(p.name) has exited.")
        case .starting, .running: break
        }
    }

    /// Ends every request to hear about `target`, with one line to each asker. The line is queued like any
    /// message, so the usual holds apply. It carries the target's tag and says it comes from the bus, because
    /// the target did not write it.
    private func tellWatchers(of target: Pane, _ news: String) {
        let watchers = target.watchers
        target.watchers = []
        for watcher in watchers { tell(watcher.asker, about: target, news) }
    }

    private func tell(_ asker: Pane, about target: Pane, _ news: String) {
        asker.queue.append((sender: target, text: "Bus notice: " + news))
        flush(asker)
    }

    /// The session this pane can resume, nil before its first turn.
    public func sessionId(_ name: String) -> String? { pane(named: name)?.sessionId }

    /// For a pane whose session the app chose or already knows.
    public func setSession(_ name: String, _ id: String?) { pane(named: name)?.sessionId = id }

    public func setModel(_ name: String, _ model: String) {
        guard let p = pane(named: name), p.model != model else { return }
        p.model = model
        onChange?()
    }

    /// What an owner keystroke did to the pane's composer.
    public enum OwnerKey: Equatable {
        /// May have put text in the composer: a character, a paste, a recalled prompt, an editing chord.
        case text
        /// Enter: a submission in a shell; in a harness only its UserPromptSubmit hook proves one.
        case submit
        /// Emptied the composer (Ctrl-C): known empty.
        case clear
        /// Moved or deleted: whatever was there may still be there.
        case other
        /// Not the owner at all: the terminal answering the program's query.
        case reply
    }

    /// The owner typed into the pane: hold relayed messages for a moment, and while text may be unsent.
    public func noteOwnerInput(_ name: String, _ key: OwnerKey = .text) {
        guard let p = pane(named: name), key != .reply else { return }
        p.lastOwnerInput = now()
        let before = p.hasDraft
        switch key {
        case .text: p.hasDraft = true; p.typedSinceSubmit = true
        case .clear: p.hasDraft = false; p.typedSinceSubmit = false
        case .submit:
            p.typedSinceSubmit = false
            if p.kind == .shell || p.kind == .runner { p.hasDraft = false }   // no hooks there: Enter is it
        case .other, .reply: break
        }
        if before != p.hasDraft { onChange?() }
    }

    /// Delivers what can be delivered now and notices turns that ended without a Stop hook.
    /// The app calls this once a second.
    public func tick() {
        for p in panes {
            if p.state == .running || p.state == .starting { watchQuiet(p) }
            flush(p)
            expireWatchers(of: p)
        }
    }

    private func expireWatchers(of target: Pane) {
        let limit = TimeInterval(Bus.watchHours * 3600)
        let expired = target.watchers.filter { now().timeIntervalSince($0.since) >= limit }
        guard !expired.isEmpty else { return }
        target.watchers.removeAll { watcher in expired.contains { $0.asker === watcher.asker } }
        for watcher in expired {
            tell(watcher.asker, about: target, "nothing from \(target.name) in \(Bus.watchHours) hours; the request is dropped.")
        }
    }

    private func watchQuiet(_ p: Pane) {
        guard let io = p.io else { return }
        let screen = io.visibleText()
        if p.kind == .runner, p.state == .starting, p.model.isEmpty, let fetching = Bus.servingLine(screen) {
            setModel(p.name, "fetching \(fetching)")
        }
        let hash = screen.hashValue
        if hash != p.screenHash || p.quietSince == nil {
            p.screenHash = hash
            p.quietSince = now()
            return
        }
        let quiet = now().timeIntervalSince(p.quietSince!)
        switch p.state {
        case .running where quiet >= idleAfterQuiet && p.kind != .runner:
            setState(p.name, .idle)
        case .starting where quiet >= readyAfterQuiet:
            if let fingerprint = IdleFingerprint.text(for: p.kind), screen.contains(fingerprint) {
                // A server that listens is running for good; a harness showing its composer is idle.
                setState(p.name, p.kind == .runner ? .running : .idle)
            }
        default:
            break
        }
    }

    // MARK: the configured relay

    /// Answers /relay when a relay is configured, later and off the main actor, since the program may take
    /// seconds and everything here runs on it. False leaves the request to `handle`, so with no config the
    /// route is what it always was: an unknown operation.
    public func relay(path: String, token: String?, body: Data, reply: @escaping @MainActor (Int, Data) -> Void) -> Bool {
        guard path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "relay", let config = relayConfig,
              let program = Relay.program(config: config) else { return false }
        func refuse(_ result: (status: Int, body: Data)) -> Bool {
            reply(result.status, result.body)
            return true
        }
        guard let token, let sender = panes.first(where: { $0.token == token }) else {
            return refuse(error(401, "unknown or missing X-Dojo-Token"))
        }
        guard case .success(let path) = program else {
            guard case .failure(let why) = program else { return true }
            return refuse(error(403, why))
        }
        let args = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch Relay.words(args?["args"]) {
        case .failure(let why):
            return refuse(error(400, why))
        case .success(let words):
            guard !relayRunning else { return refuse(error(429, "a relay is already running; try again")) }
            relayRunning = true
            Relay.run(program: path, words: words, pane: sender.name) { outcome in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.relayRunning = false
                    let result = self.ok(["code": Int(outcome.code), "stdout": outcome.stdout, "stderr": outcome.stderr,
                                          "timedOut": outcome.timedOut, "truncated": outcome.truncated])
                    reply(result.status, result.body)
                }
            }
            return true
        }
    }

    // MARK: HTTP entry point

    /// Handles one request. `path` is the operation: /panes, /send, /read, /state, /watch or /hook.
    public func handle(path: String, token: String?, body: Data) -> (status: Int, body: Data) {
        guard let token, let sender = panes.first(where: { $0.token == token }) else {
            return error(401, "unknown or missing X-Dojo-Token")
        }
        let args: [String: Any]
        if body.isEmpty {
            args = [:]
        } else if let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            args = parsed
        } else {
            return error(400, "body must be a JSON object")
        }
        let op = path.split(separator: "?").first.map { String($0) }?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        switch op {
        case "panes":
            return ok(["you": sender.name, "panes": panes.map { info($0).json }])
        case "send":
            return send(from: sender, args)
        case "read":
            return read(args)
        case "state":
            guard let target = target(args) else { return noPane(args) }
            return ok(info(target).json)
        case "watch":
            return watch(from: sender, args)
        case "hook":
            applyHook(sender, args)
            return (200, Data())
        default:
            return error(404, "unknown operation '\(op)'; use panes, send, read, state or watch")
        }
    }

    // MARK: operations

    /// Asks to hear once when the target next goes idle, reaches a prompt or exits. The reply gives its state
    /// now: a target that is idle already may never change, and then the request runs out.
    private func watch(from sender: Pane, _ args: [String: Any]) -> (status: Int, body: Data) {
        guard let target = target(args) else { return noPane(args) }
        guard target !== sender else { return error(400, "a pane cannot watch itself") }
        guard target.state != .exited else { return error(409, "\(target.name) has exited") }
        target.watchers.removeAll { $0.asker === sender }
        target.watchers.append((asker: sender, since: now()))
        return ok(["pane": target.name, "state": target.state.rawValue])
    }

    private func send(from sender: Pane, _ args: [String: Any]) -> (status: Int, body: Data) {
        guard let target = target(args) else { return noPane(args) }
        guard target.state != .exited else { return error(409, "\(target.name) has exited") }
        guard target.kind != .runner else { return error(409, "\(target.name) is the model server, not a harness") }
        let text = Delivery.sanitize(args["text"] as? String ?? "")
        guard !text.isEmpty else { return error(400, "text is empty") }
        guard text.count <= Bus.maxMessageLength else { return error(413, "text is longer than \(Bus.maxMessageLength) characters") }
        let before = target.queue.count
        target.queue.append((sender: sender, text: text))
        flush(target)
        let delivered = target.queue.count <= before
        var result: [String: Any] = ["pane": target.name, "delivered": delivered, "queued": target.queue.count, "state": target.state.rawValue]
        if delivered {
            if target.state == .running {
                result["note"] = "\(target.name) is busy; the message is in its input and it reads it when its current step ends."
            }
        } else if target.state == .prompt {
            result["note"] = "\(target.name) is at a prompt; the bus never types into a prompt. Queued until it is idle."
        } else if target.hasDraft {
            result["note"] = "the owner has unsent text in \(target.name); queued until it is sent, cleared, or the composer shows empty."
        } else {
            result["note"] = "\(target.name) is \(target.state.rawValue); queued until it is idle."
        }
        onChange?()
        return ok(result)
    }

    private func read(_ args: [String: Any]) -> (status: Int, body: Data) {
        guard let target = target(args) else { return noPane(args) }
        let requested = (args["lines"] as? NSNumber)?.intValue ?? 40
        let lines = min(max(requested, 1), Bus.maxReadLines)
        let text = Bus.lastLines(target.io?.screenText() ?? "", lines)
        return ok(["pane": target.name, "state": target.state.rawValue, "text": text])
    }

    private func applyHook(_ pane: Pane, _ event: [String: Any]) {
        // SessionStart may carry `model`; Claude Code's PostModelSwitch carries the new one as `to_model`.
        if let model = (event["to_model"] ?? event["model"]) as? String, !model.isEmpty, model != pane.model {
            pane.model = model
            onChange?()
        }
        pane.quietSince = nil
        // Not SessionStart: a session with no turn yet has nothing to resume, and resuming it fails.
        if event["hook_event_name"] as? String != "SessionStart", let id = event["session_id"] as? String,
           SessionId.isValid(id), id != pane.sessionId {
            pane.sessionId = id
            onSession?()
        }
        // The harness took the composer (as a prompt, or as a local command or shell line that pi reports
        // as UserInputSubmitted): it is empty now, unless keys came after the Enter that sent it, in which
        // case the hook is for an earlier prompt and a newer draft is in the composer.
        // pi reports the editor submission separately: agent_start can arrive later, or start a
        // queued turn, while a new draft is already present.
        if let name = event["hook_event_name"] as? String,
           name == "UserInputSubmitted" || (name == "UserPromptSubmit" && pane.kind != .pi),
           pane.hasDraft, !pane.typedSinceSubmit {
            pane.hasDraft = false
            onChange?()
        }
        guard pane.state != .exited,
              let name = event["hook_event_name"] as? String,
              let next = HookMapping.next(event: name, notificationType: event["notification_type"] as? String, current: pane.state)
        else { return }
        // Before the state changes: a prompt reported twice is one prompt.
        let attention: Attention? = next == .prompt && pane.state != .prompt ? .prompt
            : next == .idle && pane.turnOpen ? .finished : nil
        if next == .running { pane.turnOpen = true }
        if next == .idle { pane.turnOpen = false }
        // Here, not in setState: after the still-screen rule the state does not change, and an asker who
        // watched again is waiting for exactly this.
        if attention == .finished { tellWatchers(of: pane, "\(pane.name) finished its turn.") }
        setState(pane.name, next)
        if let attention { onAttention?(pane.name, attention) }
    }

    /// Types the whole queue as one input if the pane is idle or running and the owner is not typing
    /// there and has nothing unsent. A running harness keeps the input in its own queue and reads it
    /// when its current step ends, which is sooner than the end of its turn.
    private func flush(_ p: Pane) {
        guard p.state == .idle || p.state == .running, !p.queue.isEmpty, !p.enterPending, let io = p.io else { return }
        if let last = p.lastOwnerInput, now().timeIntervalSince(last) < ownerQuietInterval { return }
        // A hook ends a draft hold, but a turn the harness refuses fires none, and the owner's text is gone
        // from the composer all the same. The screen showing it empty ends the hold too (D18). Only after the
        // owner has been quiet, so a key not yet drawn cannot be missed.
        if p.hasDraft {
            guard Composer.shownEmpty(kind: p.kind, screen: io.screenText()) else { return }
            p.hasDraft = false
            p.typedSinceSubmit = false
        }
        let message = p.queue.map { Delivery.line(from: $0.sender.name, text: $0.text) }.joined(separator: "\n")
        p.queue.removeAll()
        io.write(Delivery.bytes(message, bracketedPaste: io.bracketedPasteEnabled))
        if p.kind != .shell { p.state = .running }
        if submitDelay > 0 {
            // Enter comes a moment later, and only if nothing changed meanwhile: a prompt that opened, or
            // owner keys typed after the paste, would make Enter send the wrong thing.
            p.enterPending = true
            let pasted = now()
            schedule(submitDelay) { [weak self, weak p, weak io] in
                guard let self, let p else { return }
                p.enterPending = false
                let ownerTyped = p.lastOwnerInput.map { $0 > pasted } ?? false
                if p.state == .idle || p.state == .running, !p.hasDraft, !ownerTyped { io?.write(Delivery.enter) }
                self.flush(p)
            }
        } else {
            io.write(Delivery.enter)
        }
        onChange?()
    }

    // MARK: helpers

    private func pane(named name: String) -> Pane? { panes.first { $0.name == name } }

    private func target(_ args: [String: Any]) -> Pane? {
        (args["pane"] as? String).flatMap(pane(named:))
    }

    private func info(_ p: Pane) -> Info {
        Info(name: p.name, kind: p.kind, host: p.host, state: p.state, queued: p.queue.count, model: p.model, draft: p.hasDraft)
    }

    private func noPane(_ args: [String: Any]) -> (status: Int, body: Data) {
        let name = args["pane"] as? String ?? ""
        return error(404, name.isEmpty ? "pane is missing" : "no pane named '\(name)'")
    }

    private func ok(_ object: [String: Any]) -> (status: Int, body: Data) {
        (200, (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
    }

    private func error(_ status: Int, _ message: String) -> (status: Int, body: Data) {
        (status, (try? JSONSerialization.data(withJSONObject: ["error": message], options: [.sortedKeys])) ?? Data())
    }

    /// What the Runner start script says it serves ("Serving REPO[:TAG] ..."), as the file's own name.
    static func servingLine(_ screen: String) -> String? {
        guard let line = screen.split(separator: "\n").first(where: { $0.hasPrefix("Serving ") }),
              let repo = line.dropFirst("Serving ".count).split(separator: " ").first else { return nil }
        return String(repo.split(separator: "/").last ?? repo)
    }

    /// The last `count` lines, trailing blanks removed.
    public static func lastLines(_ text: String, _ count: Int) -> String {
        var lines = text.components(separatedBy: "\n").map { line in
            var l = Substring(line)
            while let c = l.last, c == " " || c == "\r" || c == "\t" { l = l.dropLast() }
            return String(l)
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.suffix(count).joined(separator: "\n")
    }

    static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

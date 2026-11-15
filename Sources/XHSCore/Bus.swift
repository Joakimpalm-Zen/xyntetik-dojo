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
    /// The live screen as the terminal holds it, for the rule that looks for the harness's composer (D35.1):
    /// its lines, with rows the terminal wrapped joined again, and the line the cursor is on, taken in one
    /// step, and which of the terminal's two buffers is showing. A pane that cannot say gives its screen
    /// text row by row, no cursor and no buffer.
    func liveScreen() -> PaneScreen
}

public struct PaneScreen: Equatable, Sendable {
    public var lines: [String]
    /// Which of `lines` the cursor is on; nil when the terminal does not say.
    public var cursorLine: Int?
    /// Whether the terminal shows its alternate buffer, the one a full-screen program switches to; nil when
    /// the terminal does not say.
    public var alternate: Bool?

    public init(lines: [String], cursorLine: Int? = nil, alternate: Bool? = nil) {
        self.lines = lines
        self.cursorLine = cursorLine
        self.alternate = alternate
    }
}

public extension PaneIO {
    func liveScreen() -> PaneScreen { PaneScreen(lines: screenText().components(separatedBy: "\n")) }
}

/// The message bus: pane registry, per-pane state, queued messages and the four operations.
/// Every request carries a pane's token; the token tells the bus who is asking.
@MainActor
public final class Bus {
    /// Where the relay's config is, nil for none: see `Relay`.
    public var relayConfig: URL?
    /// The record of bus traffic, nil for none: see `BusRecord`.
    public var record: BusRecord?
    private var relayRunning = false
    /// D15 (b): the outside route's token while the owner has it switched on (OutsideRoute); nil, no route.
    public var outsideToken: String?
    /// Who sends a line from outside Dojo: never in the list of panes, never a pane anyone can read.
    private lazy var outsider = Pane(name: Outside.sender, kind: .shell, host: "", token: "", model: "", state: .idle,
                                     unrestricted: false, io: nil)
    /// When the outside lines of the last minute were sent.
    private var outsideSent: [Date] = []

    public struct Info: Equatable, Sendable {
        public let name: String
        public let kind: HarnessKind
        public let host: String
        public let state: PaneState
        public let queued: Int
        public let model: String
        /// The owner has unsent text in the pane; the bus holds its queue until that is sent or cleared.
        public let draft: Bool
        /// The pane's screen shows no composer (a dialog is open there, or a screen the bus does not know):
        /// the bus holds its queue, or the Enter it owes, until one is back (D35.1).
        public let noComposer: Bool
        /// `coordinator` or `worker` once the owner has marked a coordinator (D21.2); empty before, and for
        /// panes that are not agents.
        public let role: String
        /// The panes a worker may read, by the owner's grant.
        public let reads: [String]
        /// D15: what the pane says it is working on, set by the pane itself (`dojo label`); empty for none.
        public let label: String
        /// D15: when the pane's state last changed.
        public let since: Date
        /// D15: how long a labelled pane has been idle, once that is `idleFlagAfter` or more; nil otherwise.
        public let idleFlag: TimeInterval?

        var json: [String: Any] {
            ["name": name, "kind": kind.rawValue, "host": host, "state": state.rawValue, "queued": queued, "model": model,
             "draft": draft, "no_composer": noComposer, "role": role, "reads": reads, "label": label]
        }
    }

    final class Pane {
        var name: String
        let kind: HarnessKind
        let host: String
        let token: String
        var model: String
        var state: PaneState
        /// D15: when `state` last changed, by the bus's clock.
        var stateSince = Date()
        /// D15: set by the pane itself, one line.
        var label = ""
        /// The idle flag's minutes as the header last showed them, so the header redraws once a minute.
        var flaggedMinutes: Int?
        /// The harness skips its own permission prompts (D21.1, ticked); the record says so beside each delivery.
        let unrestricted: Bool
        /// When the pane last reached a permission prompt.
        var promptSince: Date?
        /// The owner marked this pane as the coordinator (D21.2); at most one pane is.
        var coordinator = false
        /// The panes this one may read while it is a worker, by the owner's grant.
        var mayRead: [ObjectIdentifier] = []
        /// Who sent what; the `[from: name]` line is built at delivery, so a renamed sender is named right.
        var queue: [(sender: Pane, text: String)] = []
        var lastOwnerInput: Date?
        /// When the owner last typed a key that can add text, apart from the other keys (D26).
        var lastOwnerText: Date?
        /// The message text is in the composer and its Enter is still to come.
        var enterPending = false
        /// D26: the bus's text is in the composer and the guard held its Enter back; it is pressed once the guard
        /// clears, unless the owner types text first, which leaves the composer to them.
        var enterOwed = false
        /// When the owed text went into the composer.
        var pastedAt: Date?
        /// The owner may have unsent text in the composer: set by any key that can add text, cleared by
        /// Ctrl-C or by the harness reporting a submission that nothing was typed after.
        var hasDraft = false
        /// Text keys came after the last Enter: a submission hook arriving now is for an earlier prompt.
        var typedSinceSubmit = false
        /// The bus looked for the harness's composer on the screen and did not see one, so it typed nothing,
        /// or held back an Enter (D35.1). True only while something waits on it: a queue, or an Enter.
        var noComposer = false
        /// What the bus last pasted into the composer and has not yet pressed Enter on: the Enter goes out
        /// only once the composer shows this, so the bus's own text is never taken for a dialog, and an Enter
        /// never goes to a screen the text did not reach.
        var pasted: String?
        /// The composer as the bus saw it when it typed `pasted`: its Enter is pressed against this, so a
        /// stand-in that was there already, or a dialog that opened under the composer, is not taken for the
        /// paste having arrived in a composer that is free.
        var look: Composer.Look?
        /// The owner emptied the composer while the bus's Enter was still to come: the text is no longer
        /// there for the bus to send.
        var enterCancelled = false
        /// The owner pressed Enter after the bus's paste and before the bus's own Enter. That sent the text
        /// only if there is evidence of it (`ownersEnter`): in a harness Enter can also accept a completion,
        /// or answer a dialog, and leave the text where it is.
        var ownerEnterAfterPaste = false
        /// A hook reported a prompt submitted from the composer, and the prompt it carried was `pasted`.
        var hookCarriedThePaste = false
        /// While an Enter is owed: the rows under the composer as last seen, each as its parts, and since
        /// when they have read like that (`footerSettled`).
        var settling: (rows: [[String]], since: Date)?
        /// Which of the terminal's two buffers the harness draws itself in, as seen when a hook last said the
        /// harness was at its composer (a turn ended, or a prompt was sent from it). A pager or an editor the
        /// owner opened shows in the other one, and can show a file that reads as a composer; the bus types
        /// nothing there. Nil until such a hook has come, and the bus then goes by the screen alone.
        var harnessBuffer: Bool?
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

        init(name: String, kind: HarnessKind, host: String, token: String, model: String, state: PaneState, unrestricted: Bool,
             io: PaneIO?) {
            self.name = name
            self.kind = kind
            self.host = host
            self.token = token
            self.model = model
            self.state = state
            self.unrestricted = unrestricted
            self.io = io
        }

        /// What the record calls the pane's permission setting; nil where there are no prompts to keep.
        var posture: String? {
            switch kind {
            case .shell, .runner: return nil
            default: return unrestricted ? "unrestricted" : "prompts"
            }
        }
    }

    /// How long a request to hear about a pane lasts.
    public static let watchHours = 12
    public static let maxMessageLength = 16_000
    public static let maxReadLines = 500
    /// D15: a label is short: an item ID or two, a word or three.
    public static let maxLabelLength = 40
    /// D15: a pane idle this long while it has a label is flagged in its header and tab.
    public var idleFlagAfter: TimeInterval = 600

    private var panes: [Pane] = []
    /// Called after any change a pane header shows.
    public var onChange: (() -> Void)?
    /// A pane's session id changed.
    public var onSession: (() -> Void)?
    /// A pane reported, through a hook, something the owner may want to know. See `Attention`.
    public var onAttention: ((String, Attention) -> Void)?
    /// The harnesses whose cursor is known to sit on the composer while it takes input. For those the cursor's
    /// line is part of the evidence the bus wants before it types (D35.1). Empty until a real pane of each
    /// harness has been looked at, by hand, at a restart of the app: a harness that draws its own cursor and
    /// parks the terminal's elsewhere would otherwise never be typed into.
    public var cursorEvidence: Set<HarnessKind> = []
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
    /// `unrestricted` is the pane's D21.1 setting, for the record.
    @discardableResult
    public func add(name: String, kind: HarnessKind, host: String = "", model: String = "", unrestricted: Bool = false,
                    io: PaneIO? = nil) -> String {
        precondition(pane(named: name) == nil, "duplicate pane name \(name)")
        let token = Bus.newToken()
        let initial: PaneState = kind == .shell ? .idle : .starting
        let p = Pane(name: name, kind: kind, host: host, token: token, model: model, state: initial, unrestricted: unrestricted,
                     io: io)
        p.stateSince = now()
        panes.append(p)
        note(["op": "open", "pane": name, "kind": kind.rawValue, "host": host, "posture": p.posture as Any])
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
        note(["op": "rename", "pane": name, "to": new])
        onChange?()
        return nil
    }

    public func remove(_ name: String) {
        let gone = pane(named: name)
        if gone != nil { note(["op": "close", "pane": name]) }
        panes.removeAll { $0.name == name }
        for p in panes { p.watchers.removeAll { $0.asker === gone } }
        if let gone { for p in panes { p.mayRead.removeAll { $0 == ObjectIdentifier(gone) } } }
        if let gone { tellWatchers(of: gone, "\(gone.name) was closed.") }
        onChange?()
    }

    public func setState(_ name: String, _ state: PaneState) {
        guard let p = pane(named: name), p.state != state else { return }
        var line: [String: Any] = ["op": "pane-state", "pane": name, "state": state.rawValue, "was": p.state.rawValue]
        if p.state == .prompt {
            // Who answered it: the owner's keys came in between, or nothing did. The bus never types into a
            // prompt, so no delivery can have.
            line["owner_keys"] = p.lastOwnerInput.map { $0 >= (p.promptSince ?? .distantPast) } ?? false
        }
        if state == .prompt { p.promptSince = now() }
        note(line)
        p.state = state
        p.stateSince = now()
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
        /// The pointer moved or the wheel turned over a pane whose program tracks the mouse (Claude Code since
        /// 2.1.322). No text, and not the owner typing: it neither holds a delivery nor stops its Enter (D26).
        case pointer
    }

    /// The owner typed into the pane: hold relayed messages for a moment, and while text may be unsent.
    public func noteOwnerInput(_ name: String, _ key: OwnerKey = .text) {
        guard let p = pane(named: name), key != .reply, key != .pointer else { return }
        p.lastOwnerInput = now()
        if key == .text { p.lastOwnerText = now() }
        // The owner emptied the composer themselves: the bus's owed Enter would only send an empty line.
        if p.enterOwed, key == .clear {
            p.enterOwed = false
            nothingWaits(p)
            note(["op": "enter", "pane": name, "outcome": "dropped", "why": "the owner emptied the composer"])
        }
        // The same while the bus's Enter is still on its way: when its moment comes there is nothing to press
        // it on, and an Enter owed for text that is gone would hold every later message.
        if p.enterPending, key == .clear { p.enterCancelled = true }
        // The owner's Enter over the bus's text is another matter: it sent the text only if something shows
        // that it did. Until then the bus's Enter stays owed.
        if p.enterOwed || p.enterPending, key == .submit { p.ownerEnterAfterPaste = true }
        // Each submission the owner makes from the keyboard, with no content.
        if key == .submit { note(["op": "owner-submit", "pane": name]) }
        let before = p.hasDraft
        switch key {
        case .text: p.hasDraft = true; p.typedSinceSubmit = true
        case .clear: p.hasDraft = false; p.typedSinceSubmit = false
        case .submit:
            p.typedSinceSubmit = false
            if p.kind == .shell || p.kind == .runner { p.hasDraft = false }   // no hooks there: Enter is it
        case .other, .reply, .pointer: break
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
            // D15: the header says how long a labelled pane has been idle, a minute at a time.
            let minutes = idleFlag(of: p).map { Int($0 / 60) }
            if minutes != p.flaggedMinutes {
                p.flaggedMinutes = minutes
                onChange?()
            }
        }
    }

    private func idleFlag(of p: Pane) -> TimeInterval? {
        guard p.state == .idle, !p.label.isEmpty else { return nil }
        let idle = now().timeIntervalSince(p.stateSince)
        return idle >= idleFlagAfter ? idle : nil
    }

    /// D15: the pane's own label, as the pane set it. One line, control characters taken out, at most
    /// `maxLabelLength` characters; empty clears it.
    private func label(_ sender: Pane, _ args: [String: Any], _ line: inout [String: Any]) -> (status: Int, body: Data) {
        guard let given = args["text"] as? String else { return error(400, "text is missing") }
        let clean = String(String.UnicodeScalarView(given.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        guard clean.count <= Bus.maxLabelLength else { return error(413, "a label is at most \(Bus.maxLabelLength) characters") }
        line["label"] = clean
        if clean != sender.label {
            sender.label = clean
            sender.flaggedMinutes = nil
            onChange?()
        }
        return ok(["pane": sender.name, "label": clean])
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

    // MARK: roles (D21.2)

    public enum Role: String, Sendable { case coordinator, worker }

    /// The pane the owner marked as the coordinator, if any.
    public var coordinatorName: String? { panes.first { $0.coordinator }?.name }

    private func role(of p: Pane) -> Role? {
        guard p.kind.isAgent, panes.contains(where: { $0.coordinator }) else { return nil }
        return p.coordinator ? .coordinator : .worker
    }

    /// Marks `name` as the coordinator, or none with nil. One pane at most: marking one unmarks the other.
    /// Until a coordinator is marked every pane may do everything, as before roles (the owner's choice).
    /// Returns a reason when the pane cannot be one.
    @discardableResult
    public func setCoordinator(_ name: String?) -> String? {
        if let name {
            guard let p = pane(named: name) else { return "no pane named '\(name)'" }
            guard p.kind.isAgent else { return "\(name) is not an agent pane; only an agent can coordinate" }
            for other in panes { other.coordinator = other === p }
        } else {
            for other in panes { other.coordinator = false }
        }
        note(["op": "role", "coordinator": name ?? ""])
        onChange?()
        return nil
    }

    /// Lets the worker `name` read `target`, or no longer.
    @discardableResult
    public func setRead(_ name: String, of target: String, allowed: Bool) -> String? {
        guard let p = pane(named: name) else { return "no pane named '\(name)'" }
        guard let t = pane(named: target), t !== p else { return "no other pane named '\(target)'" }
        p.mayRead.removeAll { $0 == ObjectIdentifier(t) }
        if allowed { p.mayRead.append(ObjectIdentifier(t)) }
        note(["op": "grant", "pane": name, "read": target, "allowed": allowed])
        onChange?()
        return nil
    }

    /// Why a worker may not do this, or nil. Only `read` and `watch` are limited: every pane may list the
    /// panes, ask a state and send (workers to each other too, the owner's choice); a pane that is not an
    /// agent, and every pane while no coordinator is marked, may do everything.
    private func refusal(_ op: String, from sender: Pane, _ args: [String: Any]) -> String? {
        guard role(of: sender) == .worker, let coordinator = panes.first(where: { $0.coordinator }),
              let target = target(args) else { return nil }
        switch op {
        case "read" where target !== sender && !sender.mayRead.contains(ObjectIdentifier(target)):
            return "read of '\(target.name)' is not allowed for '\(sender.name)', a worker pane; "
                + "ask the coordinator, '\(coordinator.name)'"
        case "watch" where target !== coordinator:
            return "watch of '\(target.name)' is not allowed for '\(sender.name)', a worker pane; "
                + "a worker watches only the coordinator, '\(coordinator.name)'"
        default:
            return nil
        }
    }

    // MARK: the configured relay

    /// Answers /relay when a relay is configured, later and off the main actor, since the program may take
    /// seconds and everything here runs on it. False leaves the request to `handle`, so with no config the
    /// route is what it always was: an unknown operation.
    public func relay(path: String, token: String?, body: Data, reply: @escaping @MainActor (Int, Data) -> Void) -> Bool {
        guard path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "relay", let config = relayConfig,
              let program = Relay.program(config: config) else { return false }
        var line: [String: Any] = ["op": "relay"]
        func refuse(_ result: (status: Int, body: Data)) -> Bool {
            let result = recorded(line, result)
            reply(result.status, result.body)
            return true
        }
        guard let token, let sender = panes.first(where: { $0.token == token }) else {
            return refuse(error(401, "unknown or missing X-Dojo-Token"))
        }
        line["from"] = sender.name
        guard case .success(let path) = program else {
            guard case .failure(let why) = program else { return true }
            return refuse(error(403, why))
        }
        let args = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        switch Relay.words(args?["args"]) {
        case .failure(let why):
            return refuse(error(400, why))
        case .success(let words):
            // Metadata only: the words are the owner's program's arguments, not a message to a pane.
            line["words"] = words.count
            guard !relayRunning else { return refuse(error(429, "a relay is already running; try again")) }
            relayRunning = true
            Relay.run(program: path, words: words, pane: sender.name) { [line] outcome in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.relayRunning = false
                    var line = line
                    line["code"] = Int(outcome.code)
                    if outcome.timedOut { line["timed_out"] = true }
                    let result = self.recorded(line, self.ok(["code": Int(outcome.code), "stdout": outcome.stdout,
                                                              "stderr": outcome.stderr, "timedOut": outcome.timedOut,
                                                              "truncated": outcome.truncated]))
                    reply(result.status, result.body)
                }
            }
            return true
        }
    }

    // MARK: HTTP entry point

    /// Handles one request. `path` is the operation: /panes, /send, /read, /state, /watch, /label or /hook.
    public func handle(path: String, token: String?, body: Data) -> (status: Int, body: Data) {
        let op = path.split(separator: "?").first.map { String($0) }?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        // D15 (b): only while the owner has it switched on; otherwise the path is what it always was.
        if let expected = outsideToken, op == Outside.sender || op.hasPrefix(Outside.sender + "/") {
            return outside(op, token: token, expected: expected, body: body)
        }
        guard let token, let sender = panes.first(where: { $0.token == token }) else {
            return recorded(["op": op], error(401, "unknown or missing X-Dojo-Token"))
        }
        let args: [String: Any]
        if body.isEmpty {
            args = [:]
        } else if let parsed = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] {
            args = parsed
        } else {
            return recorded(["op": op, "from": sender.name], error(400, "body must be a JSON object"))
        }
        // A hook is the pane reporting on itself; the state change it causes is what the record keeps.
        if op == "hook" {
            applyHook(sender, args)
            return (200, Data())
        }
        var line: [String: Any] = ["op": op, "from": sender.name]
        if let name = args["pane"] as? String { line["pane"] = name }
        if let why = refusal(op, from: sender, args) { return recorded(line, error(403, why)) }
        let result: (status: Int, body: Data)
        switch op {
        case "panes":
            result = ok(["you": sender.name, "panes": panes.map { info($0).json }])
        case "send":
            result = send(from: sender, args, &line)
        case "read":
            result = read(args, &line)
        case "state":
            guard let target = target(args) else { return recorded(line, noPane(args)) }
            result = ok(info(target).json)
        case "watch":
            result = watch(from: sender, args)
        case "label":
            result = label(sender, args, &line)
        default:
            result = error(404, "unknown operation '\(op)'; use panes, send, read, state, watch or label")
        }
        return recorded(line, result)
    }

    /// D15 (b): `/outside/send`, and nothing else. The sender is the route's, never the caller's.
    private func outside(_ op: String, token: String?, expected: String, body: Data) -> (status: Int, body: Data) {
        var line: [String: Any] = ["op": op == "outside/send" ? "send" : op, "from": Outside.sender, "via": "outside"]
        guard let token, Outside.same(token, expected) else {
            return recorded(line, error(401, "unknown or missing X-Dojo-Outside-Token"))
        }
        guard op == "outside/send" else { return recorded(line, error(404, "the outside route only sends: /outside/send")) }
        guard let args = (body.isEmpty ? [:] : (try? JSONSerialization.jsonObject(with: body))) as? [String: Any] else {
            return recorded(line, error(400, "body must be a JSON object"))
        }
        if let name = args["pane"] as? String { line["pane"] = name }
        // Free text only: a typed message (D21.5) is between panes, never from a program outside them.
        for field in Outside.paneOnly where args.keys.contains(field) {
            return recorded(line, error(400, "\(field) is not taken from outside Dojo: send free text only"))
        }
        let minute = now().addingTimeInterval(-60)
        outsideSent.removeAll { $0 < minute }
        guard outsideSent.count < Outside.perMinute else {
            return recorded(line, error(429, "more than \(Outside.perMinute) lines a minute from outside; try again later"))
        }
        let result = send(from: outsider, args, &line)
        if result.status == 200 { outsideSent.append(now()) }
        return recorded(line, result)
    }

    /// Records one operation with its outcome, and returns the result unchanged.
    private func recorded(_ line: [String: Any], _ result: (status: Int, body: Data)) -> (status: Int, body: Data) {
        var line = line
        if result.status == 200 {
            if line["outcome"] == nil { line["outcome"] = "ok" }
        } else {
            line["outcome"] = "refused"
            line["status"] = result.status
            line["reason"] = ((try? JSONSerialization.jsonObject(with: result.body)) as? [String: Any])?["error"] as? String ?? ""
            // A refused send keeps no text: nothing of it reached a pane.
            line["text"] = nil
        }
        note(line)
        return result
    }

    /// One line for the record. A field whose value is a nil optional is left out.
    private func note(_ line: [String: Any]) {
        guard let record else { return }
        record.append(line.filter { field in
            let mirror = Mirror(reflecting: field.value)
            return !(mirror.displayStyle == .optional && mirror.children.isEmpty)
        })
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

    private func send(from sender: Pane, _ args: [String: Any], _ line: inout [String: Any]) -> (status: Int, body: Data) {
        guard let target = target(args) else { return noPane(args) }
        guard target.state != .exited else { return error(409, "\(target.name) has exited") }
        guard target.kind != .runner else { return error(409, "\(target.name) is the model server, not a harness") }
        let text: String
        if let type = args["type"] {
            // D21.5: a typed message is checked here and becomes text; from then on it is a send like any other
            // (sanitised, capped, queued, held by the same guard, never approval). An unknown type is refused,
            // never passed on as text.
            guard args["text"] == nil else { return error(400, "a typed message takes fields, not text") }
            guard let type = type as? String else { return error(400, "type must be text") }
            switch Typed.render(type: type, fields: args["fields"]) {
            case .failure(let refusal): return error(400, refusal.reason)
            case .success(let typed):
                text = Delivery.sanitize(typed.text)
                // Kept apart for `dojo audit --type`, with secrets taken out as on any route out of the bus.
                let tokens = panes.map(\.token)
                line["type"] = type
                line["fields"] = typed.fields.mapValues { Redact.apply($0, tokens: tokens).text }
            }
        } else {
            text = Delivery.sanitize(args["text"] as? String ?? "")
        }
        guard !text.isEmpty else { return error(400, "text is empty") }
        guard text.count <= Bus.maxMessageLength else { return error(413, "text is longer than \(Bus.maxMessageLength) characters") }
        // The owner's choice (D21.2): the record keeps the text of each send.
        line["text"] = text
        line["chars"] = text.count
        let before = target.queue.count
        target.queue.append((sender: sender, text: text))
        flush(target)
        let delivered = target.queue.count <= before
        line["outcome"] = delivered ? "delivered" : "queued"
        var result: [String: Any] = ["pane": target.name, "delivered": delivered, "queued": target.queue.count, "state": target.state.rawValue]
        if delivered {
            if target.state == .running {
                result["note"] = "\(target.name) is busy; the message is in its input and it reads it when its current step ends."
            }
        } else if target.state == .prompt {
            result["note"] = "\(target.name) is at a prompt; the bus never types into a prompt. Queued until it is idle."
        } else if target.hasDraft {
            result["note"] = "the owner has unsent text in \(target.name); queued until it is sent, cleared, or the composer shows empty."
        } else if target.noComposer {
            result["note"] = "\(target.name) shows no composer on its screen (a dialog may be open there); the bus types only "
                + "into a composer it can see. Queued until one is back."
        } else {
            result["note"] = "\(target.name) is \(target.state.rawValue); queued until it is idle."
        }
        onChange?()
        return ok(result)
    }

    /// The record says who read whom and how many lines, never what the screen showed.
    private func read(_ args: [String: Any], _ line: inout [String: Any]) -> (status: Int, body: Data) {
        guard let target = target(args) else { return noPane(args) }
        let requested = (args["lines"] as? NSNumber)?.intValue ?? 40
        let lines = min(max(requested, 1), Bus.maxReadLines)
        let screen = Bus.lastLines(target.io?.screenText() ?? "", lines)
        // D21.2: secrets are taken out of what leaves the bus, always; the pane's own screen is untouched.
        let clean = Redact.apply(screen, tokens: panes.map(\.token))
        line["lines"] = screen.isEmpty ? 0 : screen.components(separatedBy: "\n").count
        line["redacted"] = clean.count
        return ok(["pane": target.name, "state": target.state.rawValue, "text": clean.text, "redacted": clean.count])
    }

    private func applyHook(_ pane: Pane, _ event: [String: Any]) {
        // SessionStart may carry `model`; Claude Code's PostModelSwitch carries the new one as `to_model`.
        var named = (event["to_model"] ?? event["model"]) as? String
        // D29: a resumed Claude Code session's SessionStart names no model, and its transcript does. Only on this
        // Mac: a pane on a host has its transcript there.
        if named?.isEmpty ?? true, event["hook_event_name"] as? String == "SessionStart", pane.kind == .claude,
           pane.host.isEmpty, let path = event["transcript_path"] as? String {
            named = Transcript.lastModel(at: path)
        }
        if let model = named, !model.isEmpty, model != pane.model {
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
        // A submission the hook names: evidence for the owner's Enter only when it carries the text the bus
        // pasted AND comes after that Enter. A hook of an earlier prompt can come late, and an earlier prompt
        // can have had the very same text: a hook that was here before the Enter proves nothing about it.
        if let name = event["hook_event_name"] as? String,
           name == "UserInputSubmitted" || (name == "UserPromptSubmit" && pane.kind != .pi), pane.ownerEnterAfterPaste,
           let prompt = event["prompt"] as? String, let pasted = pane.pasted, Composer.sameText(prompt, pasted) {
            pane.hookCarriedThePaste = true
        }
        // The harness is at its composer: a turn ended, or the owner sent a prompt from it. The buffer the
        // terminal shows now is the harness's own, if a composer is on the screen: a hook can come late, while
        // an editor shows. Not at SessionStart, which a harness may report before it has drawn itself: a new
        // session only forgets what the one before it showed.
        if event["hook_event_name"] as? String == "SessionStart" { pane.harnessBuffer = nil }
        if let name = event["hook_event_name"] as? String, name != "SessionStart",
           name == "UserPromptSubmit" || HookMapping.next(event: name, notificationType: event["notification_type"] as? String, current: pane.state) == .idle,
           let screen = pane.io?.liveScreen(), let alternate = screen.alternate,
           Composer.shown(kind: pane.kind, lines: screen.lines, cursorLine: nil, afterPaste: true) == true {
            pane.harnessBuffer = alternate
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
        // An owed Enter goes first, and nothing more is typed on top of the text it is owed for.
        if p.enterOwed {
            pressOwedEnter(p)
            if p.enterOwed { return }
        }
        guard p.state == .idle || p.state == .running, !p.queue.isEmpty, !p.enterPending, let io = p.io else { return }
        if let last = p.lastOwnerInput, now().timeIntervalSince(last) < ownerQuietInterval { return }
        // A hook ends a draft hold, but a turn the harness refuses fires none, and the owner's text is gone
        // from the composer all the same. The screen showing it empty ends the hold too (D18). Only after the
        // owner has been quiet, so a key not yet drawn cannot be missed.
        if p.hasDraft {
            // By the live screen, whose rows end at the pane's width (D37). The pane's whole text also gives
            // back what a wider pane once had beyond its right edge: words after the mark there made an
            // empty composer read as a draft, and the hold lasted until the owner next sent something.
            guard Composer.shownEmpty(kind: p.kind, screen: io.liveScreen().lines.joined(separator: "\n")) else { return }
            p.hasDraft = false
            p.typedSinceSubmit = false
        }
        // The bus types only into a composer it can see (D35.1). A permission prompt is known from a hook, and
        // a hook can be lost; any dialog takes the composer off the screen, hook or no hook. Unseen, the queue
        // waits and the next tick looks again.
        guard composerShown(p, io) else { return }
        let message = p.queue.map { Delivery.line(from: $0.sender.name, text: $0.text) }.joined(separator: "\n")
        var senders: [String] = []
        for entry in p.queue where !senders.contains(entry.sender.name) { senders.append(entry.sender.name) }
        // The target's posture at the time: in a pane that skips its prompts, what follows is the agent's.
        note(["op": "deliver", "pane": p.name, "senders": senders, "messages": p.queue.count, "chars": message.count,
              "posture": p.posture as Any])
        p.queue.removeAll()
        p.pasted = message
        io.write(Delivery.bytes(message, bracketedPaste: io.bracketedPasteEnabled))
        if p.kind != .shell, p.state != .running {
            p.state = .running
            p.stateSince = now()
        }
        if submitDelay > 0 {
            // Enter comes a moment later, and only if nothing changed meanwhile: a prompt that opened, or
            // owner keys typed after the paste, would make Enter send the wrong thing.
            p.enterPending = true
            let pasted = now()
            schedule(submitDelay) { [weak self, weak p, weak io] in
                guard let self, let p else { return }
                p.enterPending = false
                let cancelled = p.enterCancelled
                p.enterCancelled = false
                let textAfter = p.lastOwnerText.map { $0 > pasted } ?? false
                let keysAfter = p.lastOwnerInput.map { $0 > pasted } ?? false
                if cancelled {
                    // The owner emptied the composer: nothing of the bus's is left to send.
                    self.nothingWaits(p)
                    self.note(["op": "enter", "pane": p.name, "outcome": "dropped", "why": "the owner emptied the composer"])
                } else if p.ownerEnterAfterPaste, let io, self.ownersEnterSettledIt(p, io) {
                    // dropped there: theirs sent the text, or left a draft of their own
                } else if textAfter {
                    // The owner's words are in that composer now: the bus never sends them (D26).
                    self.nothingWaits(p)
                    self.note(["op": "enter", "pane": p.name, "outcome": "dropped", "why": "the owner typed after the paste"])
                } else if p.state == .idle || p.state == .running, !p.hasDraft, !keysAfter,
                          let io, self.composerShown(p, io, afterPaste: true, record: false) {
                    // Looked at and pressed in one step on this queue: nothing of the bus's runs in between.
                    io.write(Delivery.enter)
                    self.nothingWaits(p)
                    self.note(["op": "enter", "pane": p.name, "outcome": "sent"])
                } else {
                    // A prompt opened, the composer left the screen or something new stands under it (a dialog
                    // with no hook, D35.1), or the owner pressed a key that adds no text: the Enter waits for the guard to clear (D26). Before, it
                    // was dropped, and the text stayed in the composer for good.
                    p.enterOwed = true
                    p.pastedAt = pasted
                    let stateOK = p.state == .idle || p.state == .running
                    self.note(["op": "enter", "pane": p.name, "outcome": "owed",
                               "why": keysAfter ? "owner keys after the paste"
                                   : stateOK && !p.hasDraft ? "no composer on the screen" : "the pane is \(p.state.rawValue)"])
                }
                self.flush(p)
            }
        } else {
            io.write(Delivery.enter)
            p.pasted = nil
            p.look = nil
            note(["op": "enter", "pane": p.name, "outcome": "sent"])
        }
        onChange?()
    }

    /// The Enter the bus owed is pressed, or no longer its to press: nothing of its waits in the composer,
    /// so the header has nothing to say about one (D35.1).
    private func nothingWaits(_ p: Pane) {
        p.pasted = nil
        p.look = nil
        p.ownerEnterAfterPaste = false
        p.hookCarriedThePaste = false
        p.settling = nil
        if p.noComposer, p.queue.isEmpty {
            p.noComposer = false
            onChange?()
        }
    }

    /// D35.1: whether the bus may type into the pane, going by its screen. True for a harness the bus has no
    /// composer rule for (pi, a shell), as before. The first miss of a hold goes into the record and the pane's
    /// header says so, since a composer drawn in a way the bus does not know would otherwise hold a queue
    /// without a word.
    private func composerShown(_ p: Pane, _ io: PaneIO, afterPaste: Bool = false, record: Bool = true) -> Bool {
        let screen = io.liveScreen()
        let cursor = cursorEvidence.contains(p.kind) ? screen.cursorLine : nil
        var shown = true
        if Composer.rule(for: p.kind) == nil {
            // no rule for this harness: typed into as before
        } else if let home = p.harnessBuffer, let alternate = screen.alternate, alternate != home {
            // not the buffer the harness draws itself in: a pager or an editor is showing
            shown = false
        } else if afterPaste {
            shown = Composer.shown(kind: p.kind, lines: screen.lines, cursorLine: cursor, afterPaste: true, pasted: p.pasted, before: p.look) ?? true
        } else {
            // what the composer and the rows under it look like now is what the Enter is pressed against
            p.look = Composer.look(kind: p.kind, lines: screen.lines, cursorLine: cursor)
            shown = p.look != nil
        }
        if shown == p.noComposer {
            p.noComposer = !shown
            if !shown, record { note(["op": "hold", "pane": p.name, "why": "no composer on the screen", "messages": p.queue.count]) }
            onChange?()
        }
        return shown
    }

    /// What the owner's Enter after the bus's paste did (D35.1). Enter alone does not say: in a harness it
    /// can accept a completion, or answer a dialog.
    private enum OwnersEnter {
        /// It sent the bus's text: a free composer on the screen is empty, or shows the harness's own row
        /// for a message it has queued; or a hook after that Enter reported a submission that carried the
        /// text, and the composer holds nothing of the paste.
        case sentIt
        /// A free composer holds the bus's paste in an edited form (it shares a run of characters with it):
        /// the owner's draft now, whatever a hook said. Or it holds other text and no hook proved a
        /// submission.
        case leftADraft
        /// The composer still holds the bus's text, or there is no composer on the screen (a dialog): nothing
        /// is known, and the bus's Enter stays owed.
        case unknown
    }

    private func ownersEnter(_ p: Pane, _ io: PaneIO) -> OwnersEnter {
        // For a harness with no composer rule Enter is all there is, as before.
        guard Composer.rule(for: p.kind) != nil, let text = p.pasted else { return .sentIt }
        // The screen first. Where it shows no free composer (a dialog, the other buffer, text over several
        // rows), or one that still holds the bus's text, only a hook can say the text was sent.
        let hook: OwnersEnter = p.hookCarriedThePaste ? .sentIt : .unknown
        let screen = io.liveScreen()
        if let home = p.harnessBuffer, let alternate = screen.alternate, alternate != home { return hook }
        let cursor = cursorEvidence.contains(p.kind) ? screen.cursorLine : nil
        guard let free = Composer.look(kind: p.kind, lines: screen.lines, cursorLine: cursor) else { return hook }
        if Composer.shownEmpty(kind: p.kind, screen: screen.lines.joined(separator: "\n")) { return .sentIt }
        // The harness's own row in a composer that holds no typed text: the pasted text has left it.
        if Composer.rowsOfAComposerTheTextLeft(for: p.kind).contains(free.composer) { return .sentIt }
        if Composer.holding(kind: p.kind, lines: screen.lines, cursorLine: cursor, pasted: text, before: p.look) != nil { return hook }
        // Other text in a free composer. What tells the owner's draft from anything the harness writes there
        // (a suggestion, a hint of its own) is the paste itself: text that shares a run of characters with
        // what the bus pasted is the paste, edited, in whatever part, and the owner's draft whatever a hook
        // said. Text with nothing of the paste in it is the owner's draft only when no hook after their
        // Enter proved the submission.
        if Composer.sharesARun(with: text, free.composer) { return .leftADraft }
        return p.hookCarriedThePaste ? .sentIt : .leftADraft
    }

    /// Drops the bus's Enter when the owner's own settled what it was for. A draft the owner's Enter left
    /// behind gets the draft hold, as text the owner typed does.
    private func ownersEnterSettledIt(_ p: Pane, _ io: PaneIO) -> Bool {
        let did = ownersEnter(p, io)
        guard did != .unknown else { return false }
        p.enterOwed = false
        nothingWaits(p)
        if did == .leftADraft {
            p.hasDraft = true
            p.typedSinceSubmit = true
            onChange?()
        }
        note(["op": "enter", "pane": p.name, "outcome": "dropped", "why": "the owner pressed Enter"])
        return true
    }

    /// The way back for an owed Enter whose footer changed for good (D35.1). The owner's status line can
    /// change in any word between the paste and the Enter ("1 shell" to "2 shells"), and the Enter was then
    /// owed for as long as it read differently. While an Enter is owed and the composer holds exactly what
    /// the bus pasted, rows under it that show no sign of a dialog, are no more than before the paste, and
    /// have read the same in two looks at least the owner-quiet interval apart become the rows to compare
    /// against. A row that was added never does. What this lets through is a dialog that takes the place of
    /// a footer row, with no number, frame or key hint, and stays.
    private func footerSettled(_ p: Pane, _ io: PaneIO) -> Bool {
        guard let before = p.look, let pasted = p.pasted else { return false }
        let screen = io.liveScreen()
        if let home = p.harnessBuffer, let alternate = screen.alternate, alternate != home { return false }
        let cursor = cursorEvidence.contains(p.kind) ? screen.cursorLine : nil
        guard let now = Composer.holding(kind: p.kind, lines: screen.lines, cursorLine: cursor, pasted: pasted, before: before),
              now.under.count <= before.under.count else {
            p.settling = nil
            return false
        }
        let rows = now.under.map(Composer.parts)
        guard let settling = p.settling, settling.rows == rows else {
            p.settling = (rows, self.now())
            return false
        }
        guard self.now().timeIntervalSince(settling.since) >= ownerQuietInterval else { return false }
        p.look = Composer.Look(composer: before.composer, under: now.under)
        p.settling = nil
        return composerShown(p, io, afterPaste: true, record: false)
    }

    /// D26: the Enter the guard held back, pressed once the pane is idle or running and the owner has been quiet.
    /// Never when owner text came after the paste: then the composer holds their words too.
    private func pressOwedEnter(_ p: Pane) {
        guard let io = p.io else { return }
        if let typed = p.lastOwnerText, let pasted = p.pastedAt, typed > pasted {
            p.enterOwed = false
            nothingWaits(p)
            note(["op": "enter", "pane": p.name, "outcome": "dropped", "why": "the owner typed after the paste"])
            return
        }
        // The owner pressed Enter over the bus's text, and it is gone, or no longer the bus's.
        if p.ownerEnterAfterPaste, ownersEnterSettledIt(p, io) { return }
        guard p.state == .idle || p.state == .running, !p.hasDraft else { return }
        if let last = p.lastOwnerInput, now().timeIntervalSince(last) < ownerQuietInterval { return }
        guard composerShown(p, io, afterPaste: true, record: false) || footerSettled(p, io) else { return }
        let unproven = p.ownerEnterAfterPaste
        p.enterOwed = false
        io.write(Delivery.enter)
        nothingWaits(p)
        // The owner's Enter did not send this text, so the bus's may not have either (a completion took the
        // one, and can take the other). The pane keeps its draft hold until a hook reports the submission or
        // the composer shows empty, as for the owner's own text.
        if unproven {
            p.hasDraft = true
            p.typedSinceSubmit = false
        }
        if p.kind != .shell { p.state = .running }
        note(["op": "enter", "pane": p.name, "outcome": "sent", "late": true])
        onChange?()
    }

    // MARK: helpers

    private func pane(named name: String) -> Pane? { panes.first { $0.name == name } }

    private func target(_ args: [String: Any]) -> Pane? {
        (args["pane"] as? String).flatMap(pane(named:))
    }

    private func info(_ p: Pane) -> Info {
        Info(name: p.name, kind: p.kind, host: p.host, state: p.state, queued: p.queue.count, model: p.model, draft: p.hasDraft,
             noComposer: p.noComposer, role: role(of: p)?.rawValue ?? "",
             reads: panes.filter { p.mayRead.contains(ObjectIdentifier($0)) }.map(\.name),
             label: p.label, since: p.stateSince, idleFlag: idleFlag(of: p))
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

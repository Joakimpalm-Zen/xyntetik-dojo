import Foundation

/// Activity level Dojo asks macOS to hold from `ProcessInfo.beginActivity` while panes live.
///
/// App Nap throttles timers (`Bus.tick` at 1 s and `asyncAfter` submit retries) when Dojo is in the
/// background or minimized, delaying self-healing paths (`pressOwedEnter`, draft hold recovery,
/// quiet-screen idle checks). Display sleep is not prevented.
public enum PowerScope: Equatable, Sendable {
    /// No open panes: no activity assertion held.
    case none
    /// At least one open pane, none running: keep App Nap off while allowing idle system sleep.
    case openPanes
    /// At least one pane is `.running`: keep App Nap and idle system sleep off; display may sleep.
    case runningPanes

    public static func scope(for states: [PaneState]) -> PowerScope {
        if states.contains(.running) { return .runningPanes }
        if !states.isEmpty { return .openPanes }
        return .none
    }

    public var reason: String {
        switch self {
        case .none: return ""
        case .openPanes: return "Dojo panes open"
        case .runningPanes: return "Dojo agent running"
        }
    }

    #if os(macOS)
    public var options: ProcessInfo.ActivityOptions? {
        switch self {
        case .none: return nil
        case .openPanes: return .userInitiatedAllowingIdleSystemSleep
        case .runningPanes: return .userInitiated
        }
    }
    #endif
}

/// Holds at most one `ProcessInfo` activity token for the active `PowerScope`, acquiring a new
/// token before releasing the old one so transitions leave no unasserted gap.
public final class PowerHold {
    #if os(macOS)
    public typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    public typealias EndActivity = (NSObjectProtocol) -> Void

    private let begin: BeginActivity
    private let end: EndActivity
    private var token: NSObjectProtocol?
    public private(set) var scope: PowerScope = .none

    public init(
        begin: @escaping BeginActivity = { ProcessInfo.processInfo.beginActivity(options: $0, reason: $1) },
        end: @escaping EndActivity = { ProcessInfo.processInfo.endActivity($0) }
    ) {
        self.begin = begin
        self.end = end
    }

    public func update(states: [PaneState]) {
        let next = PowerScope.scope(for: states)
        guard next != scope else { return }
        let nextToken = next.options.map { begin($0, next.reason) }
        if let token { end(token) }
        token = nextToken
        scope = next
    }

    public func release() {
        update(states: [])
    }

    deinit {
        if let token { end(token) }
    }
    #endif
}

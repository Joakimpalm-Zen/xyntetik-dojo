import Foundation
import Testing
@testable import XHSCore

@Suite struct PowerHoldTests {
    @Test func scopeFollowsOpenAndRunningPaneStates() {
        #expect(PowerScope.scope(for: []) == .none)
        #expect(PowerScope.scope(for: [.starting]) == .openPanes)
        #expect(PowerScope.scope(for: [.idle]) == .openPanes)
        #expect(PowerScope.scope(for: [.prompt]) == .openPanes)
        #expect(PowerScope.scope(for: [.exited]) == .openPanes)
        #expect(PowerScope.scope(for: [.idle, .prompt]) == .openPanes)
        #expect(PowerScope.scope(for: [.idle, .running]) == .runningPanes)
        #expect(PowerScope.scope(for: [.running]) == .runningPanes)

        #if os(macOS)
        #expect(PowerScope.none.options == nil)
        #expect(PowerScope.openPanes.options == .userInitiatedAllowingIdleSystemSleep)
        #expect(PowerScope.runningPanes.options == .userInitiated)
        // Display sleep stays allowed in every scope.
        #expect(PowerScope.openPanes.options?.contains(.idleDisplaySleepDisabled) == false)
        #expect(PowerScope.runningPanes.options?.contains(.idleDisplaySleepDisabled) == false)
        #endif
    }

    #if os(macOS)
    @Test func transitionsHoldAndReleaseWithoutGapsOrChurn() {
        final class Token: NSObject {
            let id: Int
            let options: ProcessInfo.ActivityOptions
            let reason: String
            var ended = false

            init(id: Int, options: ProcessInfo.ActivityOptions, reason: String) {
                self.id = id
                self.options = options
                self.reason = reason
            }
        }

        var nextID = 0
        var active: [Token] = []
        var log: [String] = []
        let hold = PowerHold(
            begin: { options, reason in
                nextID += 1
                let t = Token(id: nextID, options: options, reason: reason)
                active.append(t)
                log.append("begin:\(t.id):\(options.rawValue)")
                return t
            },
            end: { obj in
                let t = obj as! Token
                t.ended = true
                active.removeAll { $0 === t }
                log.append("end:\(t.id)")
            }
        )

        hold.update(states: [])
        #expect(hold.scope == .none)
        #expect(active.isEmpty)

        // First open pane (idle): App Nap off, idle system sleep allowed.
        hold.update(states: [.idle])
        #expect(hold.scope == .openPanes)
        #expect(active.count == 1)
        #expect(active[0].options == .userInitiatedAllowingIdleSystemSleep)

        // Second idle pane: no churn.
        hold.update(states: [.idle, .prompt])
        #expect(active.count == 1)
        #expect(log.count == 1)

        // Pane starts running: new userInitiated token acquired before old token ends.
        hold.update(states: [.idle, .running])
        #expect(hold.scope == .runningPanes)
        #expect(active.count == 1)
        #expect(active[0].id == 2)
        #expect(active[0].options == .userInitiated)
        #expect(log == [
            "begin:1:\(ProcessInfo.ActivityOptions.userInitiatedAllowingIdleSystemSleep.rawValue)",
            "begin:2:\(ProcessInfo.ActivityOptions.userInitiated.rawValue)",
            "end:1",
        ])

        // One running pane finishes while another still runs: stays runningPanes with no churn.
        hold.update(states: [.idle, .running])
        #expect(active.count == 1)
        #expect(active[0].id == 2)

        // Last running pane goes idle: downgrades to openPanes (system sleep allowed again).
        hold.update(states: [.idle, .idle])
        #expect(hold.scope == .openPanes)
        #expect(active.count == 1)
        #expect(active[0].id == 3)
        #expect(active[0].options == .userInitiatedAllowingIdleSystemSleep)

        // All panes close: assertion released completely.
        hold.release()
        #expect(hold.scope == .none)
        #expect(active.isEmpty)
        #expect(log.last == "end:3")
    }
    #endif
}

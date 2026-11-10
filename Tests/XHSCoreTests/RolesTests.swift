import Foundation
import Testing
@testable import XHSCore

/// Roles on the bus (D21.2, step 3), with the owner's choices: everything as before until a coordinator is
/// marked, and workers may send to each other.
@MainActor
@Suite struct RolesTests {
    let bus = Bus()
    let coord: String, w1: String, w2: String, sh: String
    let ios = (MockIO(), MockIO(), MockIO(), MockIO())

    init() {
        bus.submitDelay = 0
        coord = bus.add(name: "coord", kind: .claude, io: ios.0)
        w1 = bus.add(name: "w1", kind: .codex, io: ios.1)
        w2 = bus.add(name: "w2", kind: .pi, io: ios.2)
        sh = bus.add(name: "sh", kind: .shell, io: ios.3)
    }

    func call(_ op: String, _ args: [String: Any], as token: String) -> (Int, [String: Any]) {
        let r = bus.handle(path: "/" + op, token: token, body: body(args))
        return (r.status, json(r.body))
    }

    func roles() -> [String: String] {
        let panes = call("panes", [:], as: sh).1["panes"] as? [[String: Any]] ?? []
        return Dictionary(uniqueKeysWithValues: panes.map { ($0["name"] as! String, $0["role"] as! String) })
    }

    @Test func withNoCoordinatorEveryPaneMayDoEverything() {
        #expect(call("read", ["pane": "w2"], as: w1).0 == 200)
        #expect(call("watch", ["pane": "w2"], as: w1).0 == 200)
        let noRoles = roles().values.allSatisfy { $0.isEmpty }
        #expect(noRoles)
    }

    @Test func aWorkerReadsOnlyWhatTheOwnerGranted() {
        #expect(bus.setCoordinator("coord") == nil)
        let (status, refused) = call("read", ["pane": "w2"], as: w1)
        #expect(status == 403)
        #expect(refused["error"] as? String
            == "read of 'w2' is not allowed for 'w1', a worker pane; ask the coordinator, 'coord'")
        #expect(call("read", ["pane": "w1"], as: w1).0 == 200)       // its own screen
        #expect(call("read", ["pane": "w1"], as: coord).0 == 200)    // the coordinator reads every pane
        #expect(call("read", ["pane": "coord"], as: w1).0 == 403)
        #expect(bus.setRead("w1", of: "w2", allowed: true) == nil)
        #expect(call("read", ["pane": "w2"], as: w1).0 == 200)
        #expect(bus.info("w1")?.reads == ["w2"])
        bus.setRead("w1", of: "w2", allowed: false)
        #expect(call("read", ["pane": "w2"], as: w1).0 == 403)
    }

    @Test func aWorkerWatchesOnlyTheCoordinator() {
        bus.setCoordinator("coord")
        let (status, refused) = call("watch", ["pane": "w2"], as: w1)
        #expect(status == 403)
        #expect(refused["error"] as? String
            == "watch of 'w2' is not allowed for 'w1', a worker pane; a worker watches only the coordinator, 'coord'")
        #expect(call("watch", ["pane": "coord"], as: w1).0 == 200)
        #expect(call("watch", ["pane": "w1"], as: coord).0 == 200)
    }

    @Test func sendsPanesAndStatesStayOpenToWorkers() {
        bus.setCoordinator("coord")
        for (target, token) in [("w2", w1), ("coord", w1), ("w1", coord)] {
            #expect(call("send", ["pane": target, "text": "hello"], as: token).0 == 200, "\(target)")
        }
        #expect(call("state", ["pane": "w2"], as: w1).0 == 200)
        #expect(roles() == ["coord": "coordinator", "w1": "worker", "w2": "worker", "sh": ""])
    }

    @Test func theOwnersShellIsNotAWorker() {
        bus.setCoordinator("coord")
        #expect(call("read", ["pane": "w2"], as: sh).0 == 200)
        #expect(call("watch", ["pane": "w2"], as: sh).0 == 200)
        #expect(bus.setCoordinator("sh") == "sh is not an agent pane; only an agent can coordinate")
        #expect(bus.coordinatorName == "coord")
    }

    @Test func theMarkMovesFollowsARenameAndGoesWithItsPane() {
        bus.setCoordinator("coord")
        bus.setCoordinator("w1")
        #expect(roles()["coord"] == "worker")
        #expect(roles()["w1"] == "coordinator")
        bus.setRead("w2", of: "coord", allowed: true)
        #expect(bus.rename("w1", to: "lead") == nil)
        #expect(bus.rename("coord", to: "old") == nil)
        #expect(bus.coordinatorName == "lead")
        #expect(bus.info("w2")?.reads == ["old"])
        bus.remove("old")
        #expect(bus.info("w2")?.reads == [])
        bus.remove("lead")
        // no coordinator left: as before roles
        #expect(bus.coordinatorName == nil)
        #expect(call("read", ["pane": "sh"], as: w2).0 == 200)
        #expect(roles()["w2"] == "")
    }

    @Test func marksGrantsAndRefusalsAreRecorded() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dojo-roles-\(UUID().uuidString)")
        bus.record = BusRecord(directory: folder)
        bus.setCoordinator("coord")
        bus.setRead("w1", of: "w2", allowed: true)
        _ = call("watch", ["pane": "w2"], as: w1)
        bus.setCoordinator(nil)
        let lines = BusRecord.files(in: folder).flatMap { f in
            ((try? String(contentsOf: f, encoding: .utf8)) ?? "").split(separator: "\n").map { json(Data($0.utf8)) }
        }
        let ops = lines.map { $0["op"] as? String ?? "" }
        #expect(ops == ["role", "grant", "watch", "role"])
        #expect(lines[0]["coordinator"] as? String == "coord")
        #expect(lines[1]["read"] as? String == "w2" && lines[1]["allowed"] as? Bool == true)
        #expect(lines[2]["outcome"] as? String == "refused" && lines[2]["status"] as? Int == 403)
        #expect((lines[2]["reason"] as? String)?.hasPrefix("watch of 'w2' is not allowed for 'w1'") == true)
        #expect(lines[3]["coordinator"] as? String == "")
    }
}

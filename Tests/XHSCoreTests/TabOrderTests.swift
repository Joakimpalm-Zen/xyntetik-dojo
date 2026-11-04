import Testing
@testable import XHSCore

@Suite struct TabOrderTests {
    @Test func tabsCycleThroughTheOverview() {
        let panes = ["a", "b", "c"]
        #expect(TabOrder.next(after: nil, in: panes) == "a")
        #expect(TabOrder.next(after: "a", in: panes) == "b")
        #expect(TabOrder.next(after: "c", in: panes) == nil)
        #expect(TabOrder.previous(before: nil, in: panes) == "c")
        #expect(TabOrder.previous(before: "a", in: panes) == nil)
        #expect(TabOrder.previous(before: "c", in: panes) == "b")
    }

    @Test func aClosedTabLeadsToTheOverviewOrTheFirstPane() {
        #expect(TabOrder.next(after: "gone", in: ["a"]) == "a")
        #expect(TabOrder.previous(before: "gone", in: ["a"]) == "a")
        #expect(TabOrder.next(after: nil as String?, in: []) == nil)
    }
}

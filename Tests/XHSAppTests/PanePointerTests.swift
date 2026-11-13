import AppKit
import SwiftTerm
import Testing
@testable import XHSApp

/// D19: over a pane the pointer is AppKit's I-beam drawn white with a dark edge (the owner's pick, option 5),
/// asked for the way AppKit asks; SwiftTerm's own view, and everything else, keep AppKit's pointers.
@Suite(.serialized) @MainActor struct PanePointerTests {
    /// AppKit calls `cursorUpdate(with:)` through the Objective-C runtime, so the test does too.
    private func pointer(over view: NSView) -> NSCursor? {
        NSCursor.arrow.set()
        view.perform(#selector(NSView.cursorUpdate(with:)), with: nil)
        return NSCursor.current
    }

    @Test func aPaneShowsDojosIBeamNotAppKits() {
        let shown = pointer(over: TerminalPane(name: "p"))
        #expect(shown !== NSCursor.iBeam, "the thin I-beam that reads as one more letter")
        #expect(shown === PanePointer.cursor)
    }

    @Test func swiftTermsOwnViewKeepsAppKitsIBeam() {
        #expect(pointer(over: TerminalView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))) === NSCursor.iBeam)
    }

    @Test func itIsAppKitsIBeamWhiteWithADarkEdgeTwoPointsWide() throws {
        let c = PanePointer.cursor
        #expect(c.image.size == NSCursor.iBeam.image.size)
        #expect(c.hotSpot == NSCursor.iBeam.hotSpot)
        let rep = try #require(c.image.representations.compactMap { $0 as? NSBitmapImageRep }
            .max { $0.pixelsWide < $1.pixelsWide })
        let k = rep.pixelsWide / Int(c.image.size.width)
        // the row through the hot spot, the stem's middle
        let y = Int(c.hotSpot.y) * k
        let row = (0..<rep.pixelsWide).map { rep.colorAt(x: $0, y: y)!.usingColorSpace(.deviceRGB)! }
        let white = row.indices.filter { row[$0].alphaComponent > 0.9 && row[$0].brightnessComponent > 0.9 }
        let dark = row.indices.filter { row[$0].alphaComponent > 0.5 && row[$0].brightnessComponent < 0.2 }
        let stem = try #require(white.first.flatMap { a in white.last.map { a...$0 } })
        #expect(stem.contains(Int(c.hotSpot.x) * k), "white at the hot spot")
        #expect(Double(stem.count) >= 1.5 * Double(k) && Double(stem.count) <= 2.5 * Double(k), "about 2 points of white")
        #expect(dark.contains { $0 < stem.lowerBound } && dark.contains { $0 > stem.upperBound }, "a dark edge either side")
        #expect(white.count == stem.count, "one white stem, no gaps")
    }
}

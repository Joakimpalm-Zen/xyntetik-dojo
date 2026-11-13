import AppKit
import ObjectiveC

/// D19: the pointer over a pane. AppKit's I-beam is a thin black stroke with a thin white edge; over a pane's
/// light paper, among dark letters, it reads as one more letter and is hard to find. The owner picked (2026-11-13,
/// option 5 of a sheet of real renders) AppKit's own I-beam with its stem doubled to 2 points and its colours
/// swapped: a white I-beam with a dark outline, the same size and hot spot. Only the panes change; the header, the
/// tabs and every other part of the window keep the pointers they have.
@MainActor
enum PanePointer {
    /// The pane pointer, drawn once from AppKit's I-beam; AppKit's own when its picture has no bitmap to draw from.
    static let cursor: NSCursor = make(from: NSCursor.iBeam) ?? NSCursor.iBeam

    /// AppKit's I-beam with its dark core and its light edge each widened by half a point either way, then the core
    /// drawn white and the edge black. Built from the largest bitmap AppKit has for it, with that bitmap and a 1x
    /// and a 2x one in the picture, so it stays sharp at every pointer size.
    static func make(from beam: NSCursor) -> NSCursor? {
        let size = beam.image.size
        guard size.width > 0, size.height > 0,
              let source = beam.image.representations.compactMap({ $0 as? NSBitmapImageRep })
                .max(by: { $0.pixelsWide < $1.pixelsWide }) else { return nil }
        let w = source.pixelsWide, h = source.pixelsHigh
        let perPoint = max(1, Int((Double(w) / Double(size.width)).rounded()))
        guard let gray = rgba(w, h) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: gray)
        source.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let px = gray.bitmapData else { return nil }
        // Premultiplied grey: alpha is the whole mark, alpha minus red the dark part of it.
        var mark = [UInt8](repeating: 0, count: w * h), dark = mark
        for i in 0..<(w * h) {
            mark[i] = px[i * 4 + 3]
            dark[i] = px[i * 4 + 3] &- min(px[i * 4], px[i * 4 + 3])
        }
        let r = perPoint / 2
        let wideMark = widen(mark, w, h, by: r), wideDark = widen(dark, w, h, by: r)
        guard let out = rgba(w, h), let o = out.bitmapData else { return nil }
        for i in 0..<(w * h) {
            let a = max(wideMark[i], wideDark[i])
            // the core white, the edge black, premultiplied
            o[i * 4] = wideDark[i]; o[i * 4 + 1] = wideDark[i]; o[i * 4 + 2] = wideDark[i]; o[i * 4 + 3] = a
        }
        out.size = size
        let image = NSImage(size: size)
        for scale in [1, 2] {
            guard let rep = rgba(Int(size.width) * scale, Int(size.height) * scale) else { continue }
            NSGraphicsContext.saveGraphicsState()
            let ctx = NSGraphicsContext(bitmapImageRep: rep)
            ctx?.imageInterpolation = .high
            NSGraphicsContext.current = ctx
            out.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = size
            image.addRepresentation(rep)
        }
        image.addRepresentation(out)
        return NSCursor(image: image, hotSpot: beam.hotSpot)
    }

    private static func rgba(_ w: Int, _ h: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: w * 4, bitsPerPixel: 32)
    }

    /// Each pixel takes the largest value within `r` pixels to its left and right.
    private static func widen(_ m: [UInt8], _ w: Int, _ h: Int, by r: Int) -> [UInt8] {
        var out = m
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = 0
                for dx in max(0, x - r)...min(w - 1, x + r) { v = max(v, m[y * w + dx]) }
                out[y * w + x] = v
            }
        }
        return out
    }

    /// SwiftTerm sets `.iBeam` over its whole view in `cursorUpdate(with:)` and `resetCursorRects()`. Both are
    /// `public`, not `open`, so no subclass in this module may override them; AppKit calls them through the
    /// Objective-C runtime, so `type` gets its own two there, and SwiftTerm's `TerminalView` keeps its own.
    static func install(on type: AnyClass) {
        let update: @convention(block) (NSView, NSEvent?) -> Void = { _, _ in
            MainActor.assumeIsolated { PanePointer.cursor.set() }
        }
        let rects: @convention(block) (NSView) -> Void = { view in
            MainActor.assumeIsolated { view.addCursorRect(view.bounds, cursor: PanePointer.cursor) }
        }
        class_addMethod(type, #selector(NSView.cursorUpdate(with:)), imp_implementationWithBlock(update), "v@:@")
        class_addMethod(type, #selector(NSView.resetCursorRects), imp_implementationWithBlock(rects), "v@:")
    }
}

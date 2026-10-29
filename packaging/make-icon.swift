// The app icon, drawn from the same numbers as the site's favicon (the Ensō in the brand gradient with
// three coral dots) with Dojo's torii inside the ring, on a sheet of recycled paper, like the window. No image file is checked in; `make app` runs this.
//
//   swift packaging/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset
import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ v: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

/// Theme.Enso in Sources/XHSApp/Theme.swift holds the same geometry for the window.
enum Enso {
    static let center = CGPoint(x: 50, y: 50)
    static let radius: CGFloat = 40
    /// From the upper left (245) down the left side, along the bottom and up to the upper right (300),
    /// the long way round: the angle decreases, as the SVG's sweep flag says.
    static let startDegrees: CGFloat = 245
    static let endDegrees: CGFloat = 300 - 360
    static let strokeWidth: CGFloat = 9
    static let dots: [(x: CGFloat, y: CGFloat, r: CGFloat, color: UInt32)] =
        [(70.5, 14.9, 5.4, 0xFF7A5C), (77.8, 9.2, 2.7, 0xFF9A80), (82.6, 4.8, 1.6, 0xFFBBA8)]
}

/// Draws one icon of `size` pixels. Coordinates are y down, like the SVG; the context is flipped once.
func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: s)
    ctx.scaleBy(x: 1, y: -1)

    // macOS icon shape: a rounded square with a margin, as the system's own icons have.
    let margin = s * 0.09
    let box = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let shape = CGPath(roundedRect: box, cornerWidth: box.width * 0.225, cornerHeight: box.height * 0.225, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xECE7DB))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let paper = CGGradient(colorsSpace: space, colors: [rgb(0xF1EDE3), rgb(0xE3DED1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(paper, start: CGPoint(x: box.minX, y: box.minY), end: CGPoint(x: box.maxX, y: box.maxY), options: [])
    // The fibre flecks of recycled paper, from a fixed seed so every size gets the same sheet.
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 33) / CGFloat(1 << 31)
    }
    for _ in 0..<220 {
        let x = box.minX + next() * box.width, y = box.minY + next() * box.height
        let long = (0.8 + next() * 2.2) * s / 100, wide = (0.5 + next() * 0.6) * s / 100
        ctx.setFillColor(rgb(0x6B5E48, 0.06 + next() * 0.1))
        ctx.fillEllipse(in: CGRect(x: x, y: y, width: long, height: wide))
    }

    // The mark fills 62% of the box, centred.
    let markSize = box.width * 0.62
    let origin = CGPoint(x: box.midX - markSize / 2, y: box.midY - markSize / 2)
    let scale = markSize / 100
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }

    let arc = CGMutablePath()
    var degrees = Enso.startDegrees
    while degrees >= Enso.endDegrees {
        let a = degrees * .pi / 180
        let p = point(Enso.center.x + Enso.radius * cos(a), Enso.center.y + Enso.radius * sin(a))
        if degrees == Enso.startDegrees { arc.move(to: p) } else { arc.addLine(to: p) }
        degrees -= 1
    }
    let teal = CGGradient(colorsSpace: space, colors: [rgb(0x159A89), rgb(0x2FD0B9)] as CFArray, locations: [0, 1])!
    let gradientStart = CGPoint(x: origin.x + 10 * scale, y: origin.y)
    let gradientEnd = CGPoint(x: origin.x + 90 * scale, y: origin.y)

    ctx.saveGState()
    ctx.addPath(arc)
    ctx.setLineWidth(Enso.strokeWidth * scale)
    ctx.setLineCap(.round)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(teal, start: gradientStart, end: gradientEnd, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // The torii inside the ring, in vermilion (Theme.Enso.Torii holds the same numbers for the window).
    ctx.setStrokeColor(rgb(0xD8432B))
    ctx.setLineCap(.butt)
    ctx.setLineWidth(4.5 * scale)
    ctx.move(to: point(29, 30))
    ctx.addQuadCurve(to: point(71, 30), control: point(50, 36))
    ctx.strokePath()
    ctx.setLineWidth(3.5 * scale)
    ctx.move(to: point(34, 44)); ctx.addLine(to: point(66, 44))
    ctx.strokePath()
    ctx.setLineWidth(4.5 * scale)
    for x in [39.0, 61.0] { ctx.move(to: point(x, 36)); ctx.addLine(to: point(x, 70)) }
    ctx.strokePath()

    for dot in Enso.dots {
        let c = point(dot.x, dot.y)
        ctx.setFillColor(rgb(dot.color))
        ctx.fillEllipse(in: CGRect(x: c.x - dot.r * scale, y: c.y - dot.r * scale, width: dot.r * 2 * scale, height: dot.r * 2 * scale))
    }
    ctx.restoreGState()
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    try write(draw(size: base), "icon_\(base)x\(base).png")
    try write(draw(size: base * 2), "icon_\(base)x\(base)@2x.png")
}
print("wrote \(out)")

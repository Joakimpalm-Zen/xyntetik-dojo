import AppKit
import SwiftUI

/// The Xyntetik brand as the window uses it: the site's accent colours on a recycled-paper ground, and
/// the Ensō mark from its favicon. The ground is the same in light and dark mode: paper has one colour.
enum Theme {
    // MARK: colours

    /// Recycled paper: warm, a little grey, for the window; a shade lighter for headers and the picker;
    /// the lightest sheet for the terminals. `shade` is the header tone as an RGB triple, for the bands a
    /// harness paints white.
    static let bg = color(0xD9D5C8)
    static let surface = color(0xE1DDD0)
    static let paper = color(0xE8E4D7)
    static let shade = (red: 0xDF, green: 0xDB, blue: 0xCD)
    static let ink = color(0x16232A)
    static let muted = color(0x6F6A5F)
    static let line = color(0xC4BEAD)
    /// The terminal's text and its sixteen colours: Terminal.app's Novel profile, the warm brown ink and
    /// its muted palette, on a paper that is greyer than Novel's yellow.
    static let terminalInk = color(0x3B2322)
    static let ansi: [UInt32] = [0x000000, 0xCC0000, 0x00A600, 0x999900, 0x0000B2, 0xB200B2, 0x00A6B2, 0xBFBFBF,
                                 0x666666, 0xE50000, 0x00D900, 0xE5E500, 0x0000FF, 0xE500E5, 0x00E5E5, 0xE5E5E5]
    /// The fibre flecks in the paper, drawn over the ground by `Paper`.
    static let fleck = color(0x6B5E48)
    static let teal = color(0x14A08F)
    static let tealInk = color(0x0E7C6E)
    static let coral = color(0xFF7A5C)
    static let coralInk = color(0xC8532F)
    static let blue = color(0x4F6BD8)
    /// The Xyntetik green for the name in the title bar and the `[from: <name>]` tags.
    static let brand = color(0x14A08F)

    /// The mark's own colours, the same in both appearances.
    static let markTealStart = color(0x159A89)
    static let markTealEnd = color(0x2FD0B9)
    static let markCoral = color(0xFF7A5C)
    static let markCoralLight = color(0xFF9A80)
    static let markCoralLighter = color(0xFFBBA8)

    static func color(_ rgb: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: alpha)
    }


    // MARK: the Ensō

    /// The favicon's arc: centre (50, 50), radius 40, from the upper left round the bottom to the upper right,
    /// in a 100 by 100 box. `Icon` in packaging/make-icon.swift draws the same numbers.
    enum Enso {
        static let center = CGPoint(x: 50, y: 50)
        static let radius: CGFloat = 40
        static let startDegrees: CGFloat = 245
        static let endDegrees: CGFloat = 300
        static let strokeWidth: CGFloat = 9
        static let dots: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [(70.5, 14.9, 5.4), (77.8, 9.2, 2.7), (82.6, 4.8, 1.6)]

        /// The torii inside the ring, in vermilion: two pillars, the curved top beam (kasagi) with its
        /// upturned ends, and the tie beam (nuki) through the pillars. Same box, y down.
        enum Torii {
            static let color = 0xD8432B
            static let pillarX: (CGFloat, CGFloat) = (39, 61)
            static let pillarTop: CGFloat = 36
            static let pillarBottom: CGFloat = 70
            static let pillarWidth: CGFloat = 4.5
            static let kasagiY: CGFloat = 33
            static let kasagiHalf: CGFloat = 21
            static let kasagiWidth: CGFloat = 4.5
            static let kasagiLift: CGFloat = 3
            static let nukiY: CGFloat = 44
            static let nukiHalf: CGFloat = 16
            static let nukiWidth: CGFloat = 3.5

            /// The strokes, each as (path, width), in `rect` (y down).
            static func strokes(in rect: CGRect) -> [(Path, CGFloat)] {
                let scale = min(rect.width, rect.height) / 100
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }
                var kasagi = Path()
                kasagi.move(to: pt(50 - kasagiHalf, kasagiY - kasagiLift))
                kasagi.addQuadCurve(to: pt(50 + kasagiHalf, kasagiY - kasagiLift), control: pt(50, kasagiY + kasagiLift))
                var nuki = Path()
                nuki.move(to: pt(50 - nukiHalf, nukiY))
                nuki.addLine(to: pt(50 + nukiHalf, nukiY))
                var pillars = Path()
                for x in [pillarX.0, pillarX.1] {
                    pillars.move(to: pt(x, pillarTop))
                    pillars.addLine(to: pt(x, pillarBottom))
                }
                return [(kasagi, kasagiWidth * scale), (nuki, nukiWidth * scale), (pillars, pillarWidth * scale)]
            }
        }

        /// Points along the arc, one per degree, y down as in the SVG. From the upper left down the left
        /// side, along the bottom and up to the upper right: the long way round, with the angle decreasing
        /// (the SVG's sweep flag), leaving the break at the top.
        static var points: [CGPoint] {
            var degrees = startDegrees
            var out: [CGPoint] = []
            while degrees >= endDegrees - 360 {
                let a = degrees * .pi / 180
                out.append(CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a)))
                degrees -= 1
            }
            return out
        }

        /// The arc as a SwiftUI path in `rect` (y down).
        static func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 100
            var p = Path()
            for (i, pt) in points.enumerated() {
                let q = CGPoint(x: rect.minX + pt.x * scale, y: rect.minY + pt.y * scale)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            return p
        }
    }
}

/// The Dojo mark: the Ensō with the brand gradient and the three coral dots, and the torii inside it.
struct EnsoMark: View {
    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            let scale = min(rect.width, rect.height) / 100
            ZStack {
                Theme.Enso.path(in: rect)
                    .stroke(LinearGradient(colors: [Color(Theme.markTealStart), Color(Theme.markTealEnd)],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: Theme.Enso.strokeWidth * scale, lineCap: .round))
                ForEach(Array(Theme.Enso.Torii.strokes(in: rect).enumerated()), id: \.offset) { _, stroke in
                    stroke.0.stroke(Color(Theme.color(UInt32(Theme.Enso.Torii.color))),
                                    style: StrokeStyle(lineWidth: stroke.1, lineCap: .butt))
                }
                ForEach(Array(Theme.Enso.dots.enumerated()), id: \.offset) { i, dot in
                    Circle()
                        .fill(Color([Theme.markCoral, Theme.markCoralLight, Theme.markCoralLighter][i]))
                        .frame(width: dot.r * 2 * scale, height: dot.r * 2 * scale)
                        .position(x: dot.x * scale, y: dot.y * scale)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// The wordmark as the site sets it: "xyntetik" with a teal x.
struct Wordmark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Text("x").foregroundStyle(Color(Theme.teal))
            Text("yntetik").foregroundStyle(Color(Theme.ink))
        }
        .font(.system(size: size, weight: .semibold, design: .default))
        .tracking(-0.03 * size)
    }
}

/// A sheet of recycled paper: a tone with faint fibre flecks scattered over it. The flecks come from a fixed
/// seed, so the sheet looks the same every time it is drawn.
struct Paper: View {
    var tone: NSColor = Theme.bg
    var density: CGFloat = 1

    var body: some View {
        Color(tone).overlay(
            Canvas { context, size in
                var state: UInt64 = 0x9E37_79B9_7F4A_7C15
                func next() -> CGFloat {
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    return CGFloat(state >> 33) / CGFloat(1 << 31)
                }
                let count = Int(size.width * size.height / 900 * density)
                for _ in 0..<count {
                    let x = next() * size.width, y = next() * size.height
                    let long = 0.8 + next() * 2.2, wide = 0.5 + next() * 0.6
                    let alpha = 0.05 + next() * 0.09
                    let fleck = Path(ellipseIn: CGRect(x: x, y: y, width: long, height: wide))
                    context.fill(fleck, with: .color(Color(Theme.fleck).opacity(alpha)))
                }
            }
            .allowsHitTesting(false)
        )
    }
}

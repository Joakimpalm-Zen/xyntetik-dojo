import AppKit
import SwiftUI

/// The Xyntetik brand as the window uses it: the colour tokens of xyntetik.com (light and dark) and
/// the Ensō mark from its favicon. Every colour switches with the system appearance.
enum Theme {
    // MARK: colours (light, dark), the site's tokens

    static let bg = dynamic(light: 0xFAFAF8, dark: 0x0E1516)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x131C1E)
    static let ink = dynamic(light: 0x16232A, dark: 0xE8ECEA)
    static let muted = dynamic(light: 0x6B7A81, dark: 0x8C9A98)
    static let line = dynamic(light: 0xE3E6E4, dark: 0x223031)
    static let teal = dynamic(light: 0x14A08F, dark: 0x1FAA98)
    static let tealInk = dynamic(light: 0x0E7C6E, dark: 0x3ED2BD)
    static let coral = dynamic(light: 0xFF7A5C, dark: 0xFF8A6E)
    static let coralInk = dynamic(light: 0xC8532F, dark: 0xFFA48D)
    static let blue = dynamic(light: 0x4F6BD8, dark: 0x6E8AEE)
    static let codeBg = dynamic(light: 0xF3F4F2, dark: 0x0B1213)
    /// The Xyntetik green for the name in the title bar: the site's teal in light, the mark's bright end in dark.
    static let brand = dynamic(light: 0x14A08F, dark: 0x3ED2BD)

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

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
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

/// The Ensō mark, drawn with the brand gradient and the three coral dots.
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

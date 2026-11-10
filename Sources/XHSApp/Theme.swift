import AppKit
import SwiftUI

/// The Xyntetik brand as the window uses it: the site's accent colours on a recycled-paper ground, and
/// the Ensō mark from its favicon. The ground is the same in light and dark mode: paper has one colour.
enum Theme {
    // MARK: colours

    /// Recycled paper: warm, a little grey, for the window; a shade lighter for headers and the picker;
    /// the lightest sheet for the terminals. `shade` is the header tone as an RGB triple, for the bands a
    /// harness paints white.
    // Warm, toward Novel's tan but short of its yellow: green stays close to red so it never turns pink.
    static let bg = color(0xD8D2BA)
    static let surface = color(0xE1DBC5)
    static let paper = color(0xE8E3CD)
    /// The band behind a user's message in a pane: `terminalPaper` one step darker. It keeps that step out of
    /// focus, where the ground is this same tone.
    static let shade = (red: 0xD6, green: 0xD1, blue: 0xB9)
    static let shadeDimmed = (red: 0xCC, green: 0xC7, blue: 0xAF)
    static let ink = color(0x16232A)
    static let muted = color(0x514D45)
    static let line = color(0xC5BEA5)
    /// The rule between panes, and under the tabs and over the Runner strip: deeper and wider than a
    /// hairline, so two terminals on the same paper read as two, and a pane's foot does not blend into the
    /// status lines above it.
    static let rule = color(0x8F8770)
    static let ruleWidth: CGFloat = 2
    /// The corner of a tab and of the buttons in the picker.
    static let corner: CGFloat = 6
    /// The pane's ground, its text and its sixteen colours: Terminal.app's Novel profile, so a pane is not
    /// brighter than a Terminal window beside it (owner, 2026-11-06). The ground is a little darker than
    /// `surface`.
    static let terminalPaper = color(0xDFDBC3)
    /// The ground of the panes without the keys, one step down (owner, 2026-11-06).
    static let terminalPaperDimmed = color(0xD6D1B9)
    static let terminalInk = color(0x4D2F2D)
    static let ansi: [UInt32] = [0x000000, 0xCC0000, 0x00A600, 0x999900, 0x0000B2, 0xB200B2, 0x00A6B2, 0xBFBFBF,
                                 0x666666, 0xE50000, 0x00D900, 0xE5E500, 0x0000FF, 0xE500E5, 0x00E5E5, 0xE5E5E5]
    /// The least contrast terminal text keeps against its background, as a WCAG ratio. Novel's colours were
    /// made for its darker ground: half of them are under 3 on paper. Only colours below the limit shift.
    static let minimumContrast: CGFloat = 4.5
    /// The fibre flecks in the paper, drawn over the ground by `Paper`.
    static let fleck = color(0x6B5E48)
    /// A fill only: 2.15 on the window ground, too light for text or a thin glyph.
    static let teal = color(0x14A08F)
    static let tealInk = color(0x0B5E54)
    static let coral = color(0xFF7A5C)
    static let coralInk = color(0x8C3A21)
    static let blue = color(0x2A47BC)
    /// The x of the wordmark: large text, so it can stay lighter than `brand`, between it and `teal`.
    static let wordmarkX = color(0x0E7C6E)
    /// The state dots. They are fills, not text: in the darker text tones idle, running and exited have the
    /// same lightness and only their hue would tell them apart at this size.
    static let stateIdle = color(0x0E7C6E)
    static let stateRunning = color(0x4F6BD8)
    static let stateExited = color(0xC8532F)
    /// The Xyntetik green for the name in the title bar and the `[from: <name>]` tags.
    static let brand = color(0x0B5E54)

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

/// The wordmark: "xyntetik" with a green x.
struct Wordmark: View {
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            Text("x").foregroundStyle(Color(Theme.wordmarkX))
            Text("yntetik").foregroundStyle(Color(Theme.ink))
        }
        .font(.system(size: size, weight: .semibold, design: .default))
        .tracking(-0.03 * size)
    }
}

// MARK: buttons

/// The one button look, the owner's pick of 2026-11-10 (Bocka B6 variant 5, built in Bocka B8, here in D24):
/// flat, no bezel and no shadow, at three levels. `primary` is filled teal, for the main action; `quiet` is
/// paper with a hairline, for everything beside it; `textLink` is the label alone, for the lesser actions.
/// Bocka's Theme.swift states the same values under the same names.
enum FlatLook {
    static let corner: CGFloat = 7
    static let font = Font.system(size: 12)
    static let primaryWeight = Font.Weight.medium
    static let paddingH: CGFloat = 10
    static let paddingV: CGFloat = 3
    /// The label on teal.
    static let onTeal = Theme.color(0xFFFFFF)
    static let pressedOpacity = 0.75
    static let disabledOpacity = 0.45
    /// Under the pointer: a filled button lightens by this much white, a quiet one's hairline darkens to
    /// the rule, a link is underlined.
    static let hoverLift = 0.10
}

/// Whether the pointer is over a button. An object, not @State: this SDK's @State needs Xcode's plugin.
final class ButtonHover: ObservableObject {
    @Published var on = false
}

struct FlatButton: ButtonStyle {
    enum Level { case primary, quiet, textLink }
    let level: Level

    func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(level: level, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct FlatButtonBody<Label: View>: View {
    let level: FlatButton.Level
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled
    @StateObject private var hover = ButtonHover()

    var body: some View {
        let alpha = (pressed ? FlatLook.pressedOpacity : 1) * (isEnabled ? 1 : FlatLook.disabledOpacity)
        let over = hover.on && isEnabled
        let shape = RoundedRectangle(cornerRadius: FlatLook.corner)
        Group {
            switch level {
            case .primary:
                label
                    .font(FlatLook.font.weight(FlatLook.primaryWeight))
                    .foregroundStyle(Color(FlatLook.onTeal))
                    .padding(.horizontal, FlatLook.paddingH).padding(.vertical, FlatLook.paddingV)
                    .background(Color(Theme.tealInk), in: shape)
                    .overlay(shape.fill(Color.white.opacity(over ? FlatLook.hoverLift : 0)))
                    .contentShape(shape)
            case .quiet:
                label
                    .font(FlatLook.font)
                    .foregroundStyle(Color(Theme.ink))
                    .padding(.horizontal, FlatLook.paddingH).padding(.vertical, FlatLook.paddingV)
                    .background(Color(Theme.paper), in: shape)
                    .overlay(shape.strokeBorder(Color(over ? Theme.rule : Theme.line), lineWidth: 1))
                    .contentShape(shape)
            case .textLink:
                label
                    .font(FlatLook.font)
                    .foregroundStyle(Color(Theme.tealInk))
                    .underline(over)
                    .padding(.vertical, FlatLook.paddingV)
                    .contentShape(Rectangle())
            }
        }
        .opacity(alpha)
        .onHover { hover.on = $0 }
    }
}

extension ButtonStyle where Self == FlatButton {
    static var primary: FlatButton { FlatButton(level: .primary) }
    static var quiet: FlatButton { FlatButton(level: .quiet) }
    static var textLink: FlatButton { FlatButton(level: .textLink) }
}

/// A choice of a few, as flat segments: the chosen one on a teal wash with a teal hairline, the others quiet.
/// In place of the stock segmented control, so it sits beside the flat buttons without a bezel.
struct FlatSegments<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { option in
                let chosen = option.value == selection
                Button(option.title) { selection = option.value }
                    .buttonStyle(FlatSegment(chosen: chosen))
                    .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
    }
}

private struct FlatSegment: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: FlatLook.corner)
        configuration.label
            .font(FlatLook.font.weight(chosen ? FlatLook.primaryWeight : .regular))
            .foregroundStyle(Color(chosen ? Theme.tealInk : Theme.ink))
            .padding(.horizontal, FlatLook.paddingH + 4).padding(.vertical, FlatLook.paddingV + 1)
            .background(chosen ? Color(Theme.teal).opacity(0.16) : Color(Theme.paper), in: shape)
            .overlay(shape.strokeBorder(Color(chosen ? Theme.tealInk : Theme.line), lineWidth: 1))
            .contentShape(shape)
            .opacity(configuration.isPressed ? FlatLook.pressedOpacity : 1)
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

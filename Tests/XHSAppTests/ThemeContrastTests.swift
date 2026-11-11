import AppKit
import Testing
import XHSCore
@testable import XHSApp

@Suite @MainActor struct ThemeContrastTests {
    private func luminance(_ color: NSColor) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test func everyTextToneReadsOnEveryGround() {
        for tone in [Theme.muted, Theme.tealInk, Theme.brand, Theme.coralInk, Theme.blue] {
            for ground in [Theme.bg, Theme.surface, Theme.paper] {
                #expect(ratio(tone, ground) >= 4.5, "\(tone) on \(ground)")
            }
        }
    }

    /// Large text, 26 points, so its bar is 3.
    @Test func theWordmarkXReadsOnEveryGround() {
        for ground in [Theme.bg, Theme.surface, Theme.paper] {
            #expect(ratio(Theme.wordmarkX, ground) >= 3, "\(ground)")
        }
    }

    @Test func everyStateWordReadsOnTheHeader() {
        for state in [PaneState.idle, .running, .prompt, .exited, .starting] {
            #expect(ratio(PaneCell.tone(state), Theme.surface) >= 4.5, "\(state)")
        }
    }

    @Test func everyRunnerPhaseWordReadsOnTheStrip() {
        for state in [PaneState.starting, .running, .exited] {
            #expect(ratio(RunnerStrip.phase(state).color, Theme.surface) >= 4.5, "\(state)")
        }
    }

    @Test func aStateDotIsItsOwnFillNotTheTextTone() {
        #expect(PaneCell.fill(.running) == Theme.stateRunning)
        #expect(PaneCell.fill(.idle) == Theme.stateIdle)
        #expect(PaneCell.fill(.exited) == Theme.stateExited)
        #expect(PaneCell.fill(.prompt) == Theme.coral)
    }

    /// The panes use the colours of Terminal.app's Novel profile, as the owner picked on 2026-11-06: not
    /// brighter than the Terminal windows beside them.
    @Test func panesUseTerminalsColours() {
        #expect(ratio(Theme.terminalPaper, Theme.color(0xDFDBC3)) == 1)
        #expect(ratio(Theme.terminalInk, Theme.color(0x4D2F2D)) == 1)
        #expect(ratio(Theme.terminalInk, Theme.terminalPaper) >= 7)
    }

    /// The band behind a user's message is the owner's pick from the D28 sheet, variant 3: a very light teal
    /// tint over the pane's ground (2026-11-11). It replaced a neutral step of 1.06 to 1.14, which the owner
    /// found had lost the tint. It still shows, it is never lighter than the pane, and it leans to teal.
    @Test func theMessageBandIsTheOwnersLightTealTint() {
        #expect(Theme.shade.red == 0xD5 && Theme.shade.green == 0xD8 && Theme.shade.blue == 0xC0)
        #expect(Theme.shadeDimmed.red == 0xCC && Theme.shadeDimmed.green == 0xCE && Theme.shadeDimmed.blue == 0xB6)
        for (band, ground) in [(Theme.shade, Theme.terminalPaper), (Theme.shadeDimmed, Theme.terminalPaperDimmed)] {
            let shade = NSColor(srgbRed: CGFloat(band.red) / 255, green: CGFloat(band.green) / 255, blue: CGFloat(band.blue) / 255, alpha: 1)
            let step = ratio(shade, ground)
            #expect(step > 1.02 && step < 1.14, "the band differs from the pane by \(step)")
            #expect(ratio(shade, Theme.terminalInk) < ratio(ground, Theme.terminalInk), "the band is lighter than the pane")
            #expect(band.green > band.red, "the band has lost its teal")
        }
    }
}

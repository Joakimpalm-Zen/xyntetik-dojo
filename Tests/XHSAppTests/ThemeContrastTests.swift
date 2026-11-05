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
}

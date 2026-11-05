import AppKit
import Testing
@testable import XHSApp

@Suite @MainActor struct TerminalColourTests {
    @Test func aPaneKeepsTextReadableOnThePaper() {
        _ = NSApplication.shared
        #expect(TerminalPane(name: "t").minimumContrastRatio == 4.5)
    }
}

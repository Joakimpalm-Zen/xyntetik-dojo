import AppKit
import SwiftUI
import Testing
import XHSCore
@testable import XHSApp

@Suite @MainActor struct StateDotTests {
    /// Which pixels of the mark are inked, ignoring colour: the shape a greyscale picture still shows.
    private func silhouette(_ state: PaneState) throws -> [Bool] {
        let renderer = ImageRenderer(content: StateDot(state: state).frame(width: 14, height: 14))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                             bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] > 128 }
    }

    @Test func everyStateHasItsOwnShape() throws {
        let states: [PaneState] = [.starting, .running, .idle, .prompt, .exited]
        let shapes = try states.map(silhouette)
        for i in shapes.indices {
            #expect(shapes[i].contains(true), "\(states[i]) draws nothing")
            for j in shapes.indices where j > i {
                let apart = zip(shapes[i], shapes[j]).filter { $0 != $1 }.count
                #expect(apart > 40, "\(states[i]) and \(states[j]) differ in \(apart) pixels")
            }
        }
    }
}

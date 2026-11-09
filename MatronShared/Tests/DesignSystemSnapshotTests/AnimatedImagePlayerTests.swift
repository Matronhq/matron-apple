import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MatronModels
@testable import MatronDesignSystem

/// The player behind `PlayableImage`: frames in order and in time, loops
/// as the file asks, and frames kept only while they fit the budget.
@MainActor
final class AnimatedImagePlayerTests: XCTestCase {
    private func source(_ colors: [[UInt8]], delay: Double = 0.02, loopCount: Int = 0) -> AnimatedImageSource {
        AnimatedImageSource(data: Self.gif(colors, delay: delay, loopCount: loopCount))!
    }

    func test_playsEachFrameInOrder_andLoops() async throws {
        let player = AnimatedImagePlayer(source: source([Self.red, Self.green, Self.blue]), memoryBudget: .max)
        player.maxPixel = 40
        var shown: [[UInt8]] = []
        player.display = { shown.append(Self.centrePixel($0)) }
        player.start()
        try await waitUntil { shown.count >= 5 }
        player.stop(releasingFrames: true)
        XCTAssertEqual(Array(shown.prefix(5)), [Self.red, Self.green, Self.blue, Self.red, Self.green])
    }

    func test_aFiniteAnimation_restsOnItsLastFrame() async throws {
        let player = AnimatedImagePlayer(source: source([Self.red, Self.blue], loopCount: 1), memoryBudget: .max)
        player.maxPixel = 40
        var shown: [[UInt8]] = []
        player.display = { shown.append(Self.centrePixel($0)) }
        player.start()
        try await waitUntil { player.isFinished }
        XCTAssertEqual(shown, [Self.red, Self.blue])
        XCTAssertFalse(player.isRunning)
        // Start does nothing more until a restart.
        player.start()
        XCTAssertFalse(player.isRunning)
        player.restart()
        try await waitUntil { shown.count == 4 }
        XCTAssertEqual(shown, [Self.red, Self.blue, Self.red, Self.blue])
    }

    func test_nothingPlaysBeforeASizeIsKnown() {
        let player = AnimatedImagePlayer(source: source([Self.red, Self.blue]), memoryBudget: .max)
        player.start()
        XCTAssertFalse(player.isRunning)
    }

    func test_stopResumesAtTheFrameShowing() async throws {
        let player = AnimatedImagePlayer(source: source([Self.red, Self.green, Self.blue], delay: 0.05),
                                         memoryBudget: .max)
        player.maxPixel = 40
        var shown: [[UInt8]] = []
        player.display = { shown.append(Self.centrePixel($0)) }
        player.start()
        try await waitUntil { shown.count == 2 }
        player.stop(releasingFrames: false)
        XCTAssertEqual(player.index, 1)
        player.start()
        try await waitUntil { shown.count == 4 }
        player.stop(releasingFrames: true)
        // Resuming shows the frame it stopped on again, then carries on.
        XCTAssertEqual(shown, [Self.red, Self.green, Self.green, Self.blue])
    }

    /// Kept frames are what make the second loop free; they are only kept
    /// when the whole animation fits, and an image going off screen gives
    /// them back.
    func test_framesAreKeptOnlyWithinTheBudget_andReleasedOnStop() async throws {
        let colors = [Self.red, Self.green, Self.blue]
        let roomy = AnimatedImagePlayer(source: source(colors), memoryBudget: .max)
        roomy.maxPixel = 40
        var shown = 0
        roomy.display = { _ in shown += 1 }
        roomy.start()
        try await waitUntil { shown >= 4 }
        roomy.stop(releasingFrames: false)
        XCTAssertTrue(roomy.keepsFrames)
        XCTAssertGreaterThanOrEqual(roomy.cachedBytes, 3 * 40 * 20 * 4)
        roomy.stop(releasingFrames: true)
        XCTAssertEqual(roomy.cachedBytes, 0)

        // Two frames' worth of budget for a three-frame animation.
        let tight = AnimatedImagePlayer(source: source(colors), memoryBudget: 2 * 40 * 20 * 4)
        tight.maxPixel = 40
        shown = 0
        tight.display = { _ in shown += 1 }
        tight.start()
        try await waitUntil { shown >= 4 }
        tight.stop(releasingFrames: false)
        XCTAssertFalse(tight.keepsFrames)
        XCTAssertEqual(tight.cachedBytes, 0)
    }

    /// Smaller frames fit more of an animation in the same budget.
    func test_theBudgetIsCountedAtTheDrawnSize() {
        let player = AnimatedImagePlayer(source: source([Self.red, Self.green, Self.blue]),
                                         memoryBudget: 3 * 10 * 5 * 4)
        player.maxPixel = 40
        XCTAssertFalse(player.keepsFrames)
        player.maxPixel = 10
        XCTAssertTrue(player.keepsFrames)
    }

    #if os(macOS)
    /// Off screen means not playing: a view in no window never starts.
    func test_aViewWithNoWindow_doesNotPlay() async throws {
        let view = AnimatedImageView(source: source([Self.red, Self.blue]), fullResolution: false)
        view.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
        view.wantsPlayback = true
        view.layout()
        XCTAssertFalse(view.isOnScreen)
        XCTAssertFalse(view.isPlaying)
    }
    #endif

    // MARK: - Helpers

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static let red: [UInt8] = [255, 0, 0]
    static let green: [UInt8] = [0, 255, 0]
    static let blue: [UInt8] = [0, 0, 255]

    static func gif(_ colors: [[UInt8]], delay: Double, loopCount: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, colors.count, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        for color in colors {
            let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: CGFloat(color[0]) / 255, green: CGFloat(color[1]) / 255,
                                 blue: CGFloat(color[2]) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyGIFDictionary:
                [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func centrePixel(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        return (0..<3).map { bytes[$0] > 127 ? 255 : 0 }
    }
}

import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MatronModels
@testable import MatronChat

/// An animated GIF, APNG or WebP used to show as its first frame
/// everywhere: every decode path handed back frame 0 only.
final class AnimatedImageSourceTests: XCTestCase {
    func test_gif_readsFramesDelaysAndLoopCount() throws {
        let data = Self.animation(type: .gif, colors: [.red, .green, .blue], delays: [0.1, 0.25, 0.5], loopCount: 3)
        let source = try XCTUnwrap(AnimatedImageSource(data: data))
        XCTAssertEqual(source.frameCount, 3)
        XCTAssertEqual(source.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(source.loopCount, 3)
        XCTAssertEqual(source.delays, [0.1, 0.25, 0.5])
    }

    func test_apng_isAnimatedToo() throws {
        let data = Self.animation(type: .png, colors: [.red, .blue], delays: [0.2, 0.2], loopCount: 0)
        let source = try XCTUnwrap(AnimatedImageSource(data: data))
        XCTAssertEqual(source.frameCount, 2)
        XCTAssertEqual(source.loopCount, 0)
        XCTAssertEqual(source.delays[0], 0.2, accuracy: 0.001)
    }

    func test_stillImages_areNotAnimations() {
        let oneFrameGIF = Self.animation(type: .gif, colors: [.red], delays: [0.1], loopCount: 0)
        let stillPNG = Self.animation(type: .png, colors: [.red], delays: [0.1], loopCount: 0)
        XCTAssertNil(AnimatedImageSource(data: oneFrameGIF))
        XCTAssertNil(AnimatedImageSource(data: stillPNG))
        XCTAssertNil(AnimatedImageSource(data: Data([0xDE, 0xAD, 0xBE, 0xEF])))
    }

    /// A 0 delay is what old encoders wrote for "as fast as you can";
    /// browsers show such a frame for 100 ms, and so does ImageIO's
    /// clamped reading, which the source uses.
    func test_zeroDelay_isShownForATenthOfASecond() throws {
        let data = Self.animation(type: .gif, colors: [.red, .blue], delays: [0, 0], loopCount: 0)
        let source = try XCTUnwrap(AnimatedImageSource(data: data))
        XCTAssertEqual(source.delays, [0.1, 0.1])
    }

    func test_frames_areEachFramesOwnPicture_atTheAskedSize() throws {
        let data = Self.animation(type: .gif, colors: [.red, .green, .blue], delays: [0.1, 0.1, 0.1], loopCount: 0)
        let source = try XCTUnwrap(AnimatedImageSource(data: data))
        let full = try XCTUnwrap(source.frame(at: 2, maxPixel: nil))
        XCTAssertEqual(full.width, 40)
        XCTAssertEqual(full.height, 20)
        XCTAssertEqual(Self.centrePixel(full), Self.Color.blue.rgb)
        let small = try XCTUnwrap(source.frame(at: 1, maxPixel: 10))
        XCTAssertEqual(small.width, 10)
        XCTAssertEqual(small.height, 5)
        XCTAssertEqual(Self.centrePixel(small), Self.Color.green.rgb)
        XCTAssertNil(source.frame(at: 3, maxPixel: nil))
    }

    func test_decodedSize_scalesDownOnlyAndKeepsTheShape() {
        let native = CGSize(width: 400, height: 100)
        XCTAssertEqual(AnimatedImageSource.decodedSize(native: native, maxPixel: 200), CGSize(width: 200, height: 50))
        XCTAssertEqual(AnimatedImageSource.decodedSize(native: native, maxPixel: 800), native)
        XCTAssertEqual(AnimatedImageSource.decodedSize(native: native, maxPixel: nil), native)
        XCTAssertEqual(AnimatedImageSource.decodedSize(native: CGSize(width: 4000, height: 1), maxPixel: 100),
                       CGSize(width: 100, height: 1))
    }

    func test_nextFrame_wrapsForever_orStopsAfterTheLoopCount() throws {
        let forever = try XCTUnwrap(AnimatedImageSource(
            data: Self.animation(type: .gif, colors: [.red, .blue], delays: [0.1, 0.1], loopCount: 0)))
        var loops = 0
        XCTAssertEqual(forever.nextFrame(after: 0, completedLoops: &loops), 1)
        XCTAssertEqual(forever.nextFrame(after: 1, completedLoops: &loops), 0)
        XCTAssertEqual(loops, 1)

        let twice = try XCTUnwrap(AnimatedImageSource(
            data: Self.animation(type: .gif, colors: [.red, .blue], delays: [0.1, 0.1], loopCount: 2)))
        loops = 0
        XCTAssertEqual(twice.nextFrame(after: 1, completedLoops: &loops), 0)
        XCTAssertNil(twice.nextFrame(after: 1, completedLoops: &loops))
        XCTAssertEqual(loops, 2)
    }

    // MARK: - The decode paths carry it

    func test_sizedImageDecode_carriesTheAnimation_andAStillCarriesNone() {
        let gif = Self.animation(type: .gif, colors: [.red, .blue], delays: [0.1, 0.1], loopCount: 0)
        let decoded = SizedImage.decode(gif)
        XCTAssertEqual(decoded?.pixelSize, CGSize(width: 40, height: 20))
        XCTAssertEqual(decoded?.animation?.frameCount, 2)

        let png = Self.animation(type: .png, colors: [.red], delays: [0.1], loopCount: 0)
        XCTAssertNotNil(SizedImage.decode(png))
        XCTAssertNil(SizedImage.decode(png)?.animation)
    }

    func test_thumbnailDecode_carriesTheAnimation() {
        let gif = Self.animation(type: .gif, colors: [.red, .blue], delays: [0.1, 0.1], loopCount: 0)
        let thumbnail = SizedImage.decodeThumbnail(gif, maxPixel: 10)
        XCTAssertEqual(thumbnail?.pixelSize, CGSize(width: 10, height: 5))
        // The player decodes at its own size; the source keeps the file's.
        XCTAssertEqual(thumbnail?.animation?.pixelSize, CGSize(width: 40, height: 20))
    }

    // MARK: - Fixtures

    enum Color {
        case red, green, blue
        var rgb: [UInt8] {
            switch self {
            case .red: [255, 0, 0]
            case .green: [0, 255, 0]
            case .blue: [0, 0, 255]
            }
        }
    }

    /// A 40 × 20 image with one solid-colour frame per entry.
    static func animation(type: UTType, colors: [Color], delays: [Double], loopCount: Int) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, colors.count, nil)!
        let isGIF = type == .gif
        let container: CFString = isGIF ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
        let loopKey: CFString = isGIF ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
        let delayKey: CFString = isGIF ? kCGImagePropertyGIFDelayTime : kCGImagePropertyAPNGDelayTime
        CGImageDestinationSetProperties(destination, [container: [loopKey: loopCount]] as CFDictionary)
        for (color, delay) in zip(colors, delays) {
            CGImageDestinationAddImage(destination, solid(color), [container: [delayKey: delay]] as CFDictionary)
        }
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func solid(_ color: Color) -> CGImage {
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rgb = color.rgb.map { CGFloat($0) / 255 }
        context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        return context.makeImage()!
    }

    static func centrePixel(_ image: CGImage) -> [UInt8] {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2 + 0.5, y: -CGFloat(image.height) / 2 + 0.5,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
        // GIF palettes can round a channel by a step or two.
        return (0..<3).map { bytes[$0] > 127 ? 255 : 0 }
    }
}

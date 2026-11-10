import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MatronChat
@testable import MatronViewModels

/// Serves PNG bytes by media URL and counts the reads.
private final class StubMedia: MediaService, @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [URL: Data] = [:]
    private var reads: [URL] = []

    func set(_ data: Data, for url: URL) { lock.withLock { bytes[url] = data } }
    var readCount: Int { lock.withLock { reads.count } }

    func image(for mxc: URL) async -> Data? {
        lock.withLock { reads.append(mxc); return bytes[mxc] }
    }
}

@MainActor
final class TimelineImagesTests: XCTestCase {
    private let base = URL(string: "https://journal.example.com")!

    private func url(_ blobID: String) -> URL {
        base.appendingPathComponent("media").appendingPathComponent(blobID)
    }

    private static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    func testLoadKeepsEachPicturesPixelSize() async {
        let media = StubMedia()
        media.set(Self.png(width: 200, height: 30), for: url("strip"))
        media.set(Self.png(width: 60, height: 130), for: url("phone"))
        let images = TimelineImages()
        XCTAssertTrue(images.sizes.isEmpty)
        await images.load(["strip", "phone", "missing"], media: media, base: base)
        XCTAssertEqual(images.sizes, ["strip": CGSize(width: 200, height: 30), "phone": CGSize(width: 60, height: 130)])
        XCTAssertEqual(Set(images.images.keys), ["strip", "phone"], "a picture that didn't load has neither")
    }

    func testAPictureOffThePageLosesItsSizeWithItsImage() async {
        let media = StubMedia()
        media.set(Self.png(width: 200, height: 30), for: url("strip"))
        media.set(Self.png(width: 60, height: 130), for: url("phone"))
        let images = TimelineImages()
        await images.load(["strip", "phone"], media: media, base: base)
        await images.load(["phone"], media: media, base: base)
        XCTAssertEqual(images.sizes, ["phone": CGSize(width: 60, height: 130)])
        XCTAssertEqual(Array(images.images.keys), ["phone"])
        XCTAssertEqual(media.readCount, 2, "the picture kept is not read again")
        await images.load([], media: media, base: base)
        XCTAssertTrue(images.sizes.isEmpty)
        XCTAssertTrue(images.images.isEmpty)
    }
}

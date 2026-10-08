import XCTest
import SwiftUI
import CoreGraphics
@testable import MatronChat

/// Covers the `sizedImage(for:)` protocol-extension path: the decoded
/// image must carry its native bitmap pixel size (not the DPI-scaled
/// point size `NSImage.size` reports) so the Mac fullscreen viewer can
/// size its sheet without upscaling past 1:1.
final class MediaServiceSizedImageTests: XCTestCase {
    /// Reuses the fake from `MediaServiceFakeTests` (same module).
    private func service(stub: [URL: Data]) -> FakeMediaService {
        let svc = FakeMediaService()
        svc.stubData = stub
        return svc
    }

    func test_sizedImage_reportsNativePixelSize() async throws {
        let url = URL(string: "mxc://example/sized")!
        let svc = service(stub: [url: Self.png(width: 8, height: 5)])
        let resolved = await svc.sizedImage(for: url)
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.pixelSize, CGSize(width: 8, height: 5))
    }

    func test_sizedImage_nilForUndecodableBytes() async {
        let url = URL(string: "mxc://example/garbage")!
        let svc = service(stub: [url: Data([0xDE, 0xAD, 0xBE, 0xEF])])
        let resolved = await svc.sizedImage(for: url)
        XCTAssertNil(resolved)
    }

    func test_sizedImage_nilForMissingMedia() async {
        let svc = service(stub: [:])
        let resolved = await svc.sizedImage(for: URL(string: "mxc://example/missing")!)
        XCTAssertNil(resolved)
    }

    /// Solid-color PNG of the given pixel dimensions, generated via
    /// CoreGraphics so the test controls the exact bitmap size.
    private static func png(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}

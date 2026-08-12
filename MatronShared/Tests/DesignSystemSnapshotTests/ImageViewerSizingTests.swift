import XCTest
import CoreGraphics
@testable import MatronDesignSystem

/// Pins the Mac fullscreen-viewer display-size rule: 1:1 pixels when the
/// image fits the bound, aspect-fit downscale when it doesn't, and never
/// an upscale past the bitmap's native resolution (the "small and
/// pixelated" bug — the sheet used to stretch every bitmap into a fixed
/// 480pt slot regardless of its native size).
final class ImageViewerSizingTests: XCTestCase {
    func test_smallImage_displaysAtOneToOnePixels_notUpscaled() {
        // 320×240 px on a 2x screen = 160×120 pt is the largest size at
        // which the bitmap stays sharp. The old layout stretched it to
        // 448 pt wide.
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 320, height: 240),
            displayScale: 2,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(size, CGSize(width: 160, height: 120))
    }

    func test_largeImage_aspectFitsWithinBound() {
        // iPhone screenshot: 1206×2622 px @2x → 603×1311 pt natural,
        // height-limited by an 800 pt bound.
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 1206, height: 2622),
            displayScale: 2,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertNotNil(size)
        XCTAssertEqual(size!.height, 800, accuracy: 0.5)
        XCTAssertEqual(size!.width, 603.0 * 800.0 / 1311.0, accuracy: 0.5)
    }

    func test_wideImage_widthLimited() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 4000, height: 1000),
            displayScale: 2,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertNotNil(size)
        XCTAssertEqual(size!.width, 1000, accuracy: 0.5)
        XCTAssertEqual(size!.height, 250, accuracy: 0.5)
    }

    func test_exactFit_returnsNaturalSize() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 2000, height: 1600),
            displayScale: 2,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(size, CGSize(width: 1000, height: 800))
    }

    func test_oneXScreen_naturalSizeIsPixelSize() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 320, height: 240),
            displayScale: 1,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(size, CGSize(width: 320, height: 240))
    }

    func test_degenerateInputs_returnNil() {
        XCTAssertNil(AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: .zero,
            displayScale: 2,
            bound: CGSize(width: 1000, height: 800)
        ))
        XCTAssertNil(AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 100, height: 100),
            displayScale: 2,
            bound: .zero
        ))
    }

    func test_zeroDisplayScale_treatedAsOne() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 300, height: 200),
            displayScale: 0,
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(size, CGSize(width: 300, height: 200))
    }
}

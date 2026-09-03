import XCTest
import CoreGraphics
@testable import MatronDesignSystem

/// Pins the Mac fullscreen-viewer sizing rules.
///
/// Sheet: fills most of the presenting window (a fixed fraction of its
/// content area), never larger than the screen's visible frame, never
/// smaller than a floor that keeps the Done row and a usable image area.
/// Previously the sheet was sized to the image's native pixel size, so
/// anything smaller than the screen opened in a small box (2026-09-03,
/// Dan: "it should take up most of the area of the app").
///
/// Image: aspect-fits the viewer's image area — up as well as down — so
/// a small screenshot fills the viewer rather than sitting 1:1 in a
/// corner of it.
final class ImageViewerSizingTests: XCTestCase {

    // MARK: - Sheet size

    func test_viewerSize_isFractionOfWindowContent() {
        let size = AttachmentFullscreenViewer.viewerSize(
            windowContentSize: CGSize(width: 1400, height: 1000),
            screenVisibleSize: CGSize(width: 3000, height: 2000)
        )
        XCTAssertEqual(size.width, 1400 * AttachmentFullscreenViewer.windowFillFraction, accuracy: 0.5)
        XCTAssertEqual(size.height, 1000 * AttachmentFullscreenViewer.windowFillFraction, accuracy: 0.5)
    }

    func test_viewerSize_isClampedToScreen() {
        // Mac sheets are not clamped to the parent window by the system;
        // a window larger than the screen (or on a smaller screen) must
        // not produce a sheet that overhangs the screen.
        let size = AttachmentFullscreenViewer.viewerSize(
            windowContentSize: CGSize(width: 4000, height: 3000),
            screenVisibleSize: CGSize(width: 1440, height: 850)
        )
        let margin = AttachmentFullscreenViewer.screenMargin
        XCTAssertEqual(size.width, 1440 - margin * 2, accuracy: 0.5)
        XCTAssertEqual(size.height, 850 - margin * 2, accuracy: 0.5)
    }

    func test_viewerSize_neverBelowFloor() {
        let size = AttachmentFullscreenViewer.viewerSize(
            windowContentSize: CGSize(width: 300, height: 200),
            screenVisibleSize: CGSize(width: 1440, height: 850)
        )
        XCTAssertEqual(size, AttachmentFullscreenViewer.minimumViewerSize)
    }

    func test_viewerSize_noWindow_fallsBackToScreenFraction() {
        // Headless / no presenting window: size against the screen alone.
        let size = AttachmentFullscreenViewer.viewerSize(
            windowContentSize: nil,
            screenVisibleSize: CGSize(width: 2000, height: 1200)
        )
        XCTAssertEqual(size.width, 2000 * AttachmentFullscreenViewer.screenFillFraction, accuracy: 0.5)
        XCTAssertEqual(size.height, 1200 * AttachmentFullscreenViewer.screenFillFraction, accuracy: 0.5)
    }

    // MARK: - Image fit

    func test_smallImage_upscalesToFillBound() {
        // 320×240 px in a 1000×800 area: height-limited at 800 → 1066 wide
        // would overflow, so width-limited at 1000 → 750 tall.
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 320, height: 240),
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertNotNil(size)
        XCTAssertEqual(size!.width, 1000, accuracy: 0.5)
        XCTAssertEqual(size!.height, 750, accuracy: 0.5)
    }

    func test_largeImage_aspectFitsWithinBound() {
        // iPhone screenshot, 1206×2622 px, height-limited by an 800 pt bound.
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 1206, height: 2622),
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertNotNil(size)
        XCTAssertEqual(size!.height, 800, accuracy: 0.5)
        XCTAssertEqual(size!.width, 1206.0 * 800.0 / 2622.0, accuracy: 0.5)
    }

    func test_wideImage_widthLimited() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 4000, height: 1000),
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertNotNil(size)
        XCTAssertEqual(size!.width, 1000, accuracy: 0.5)
        XCTAssertEqual(size!.height, 250, accuracy: 0.5)
    }

    func test_exactAspect_fillsBound() {
        let size = AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 500, height: 400),
            bound: CGSize(width: 1000, height: 800)
        )
        XCTAssertEqual(size, CGSize(width: 1000, height: 800))
    }

    func test_degenerateInputs_returnNil() {
        XCTAssertNil(AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: .zero,
            bound: CGSize(width: 1000, height: 800)
        ))
        XCTAssertNil(AttachmentFullscreenViewer.imageDisplaySize(
            pixelSize: CGSize(width: 100, height: 100),
            bound: .zero
        ))
    }
}

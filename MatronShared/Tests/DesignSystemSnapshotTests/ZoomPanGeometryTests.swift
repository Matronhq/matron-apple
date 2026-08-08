import XCTest
import CoreGraphics
@testable import MatronDesignSystem

/// The fullscreen image viewer's zoom/pan rules. These are the two
/// behaviours the old viewer got wrong — zoom was anchored on the image's
/// centre (`scaleEffect`'s default) and pan didn't exist at all, so the
/// only reachable part of a zoomed image was its middle.
final class ZoomPanGeometryTests: XCTestCase {
    /// A 400x300 image fitted into a 400x800 container: full width, 300
    /// tall, letterboxed top and bottom.
    private let geo = ZoomPanGeometry(
        containerSize: CGSize(width: 400, height: 800),
        contentSize: CGSize(width: 400, height: 300)
    )

    // MARK: - Pan limits

    func test_panLimit_isZeroAtFitScale() {
        XCTAssertEqual(geo.panLimit(at: 1), .zero,
                       "an unzoomed image has nowhere to pan to")
    }

    func test_panLimit_onlyCoversTheAxisThatOverflows() {
        // At 2x the content is 800x600 in a 400x800 container: it
        // overflows horizontally by 400 (200 each side) and still doesn't
        // fill the container vertically.
        let limit = geo.panLimit(at: 2)
        XCTAssertEqual(limit.width, 200)
        XCTAssertEqual(limit.height, 0,
                       "the image must stay pinned on an axis it doesn't overflow")
    }

    func test_clampedOffset_stopsAtTheImageEdge() {
        let clamped = geo.clamped(offset: CGSize(width: 9999, height: 9999), at: 2)
        XCTAssertEqual(clamped.width, 200, "can't drag past the left/right edge")
        XCTAssertEqual(clamped.height, 0)
    }

    func test_clampedOffset_leavesAnInBoundsPanAlone() {
        let offset = CGSize(width: -50, height: 0)
        XCTAssertEqual(geo.clamped(offset: offset, at: 2), offset)
    }

    // MARK: - Scale clamping

    func test_clampedScale_holdsTheRange() {
        XCTAssertEqual(ZoomPanGeometry.clampedScale(0.2), ZoomPanGeometry.minScale)
        XCTAssertEqual(ZoomPanGeometry.clampedScale(99), ZoomPanGeometry.maxScale)
        XCTAssertEqual(ZoomPanGeometry.clampedScale(2.5), 2.5)
    }

    // MARK: - Focus-preserving zoom

    /// The regression this whole type exists for: pinching on a corner
    /// must zoom into that corner, not into the middle.
    func test_zoom_keepsThePinchedPointUnderTheFingers() {
        // Pinch centred on the image's top-left region, in container
        // coordinates (container centre is 200,400).
        let point = CGPoint(x: 100, y: 325)
        let result = geo.zoom(to: 2, around: point, from: .zero, at: 1)

        XCTAssertEqual(result.scale, 2)
        // Where does that point sit after the zoom? Screen position of a
        // content-local point p is `p * scale + offset`, measured from the
        // container centre.
        let contentLocal = CGPoint(x: point.x - 200, y: point.y - 400) // scale 1, no offset
        let after = CGPoint(
            x: contentLocal.x * result.scale + result.offset.width + 200,
            y: contentLocal.y * result.scale + result.offset.height + 400
        )
        XCTAssertEqual(after.x, point.x, accuracy: 0.001,
                       "the pinched point must not move horizontally")
        // Vertically the clamp wins here (300pt of content at 2x is 600,
        // still inside an 800pt container), which is correct: there is no
        // vertical overflow to pan into, so the image stays centred and
        // the focal point rides outward with the zoom.
        XCTAssertEqual(result.offset.height, 0)
        XCTAssertEqual(after.y, 250, accuracy: 0.001)
    }

    func test_zoom_keepsFocusOnAnAxisWithRoomToPan() {
        // Tall content in a short container: vertical overflow exists, so
        // the focal point must be honoured on both axes.
        let tall = ZoomPanGeometry(
            containerSize: CGSize(width: 400, height: 400),
            contentSize: CGSize(width: 400, height: 400)
        )
        let point = CGPoint(x: 300, y: 100)
        let result = tall.zoom(to: 2, around: point, from: .zero, at: 1)

        let contentLocal = CGPoint(x: point.x - 200, y: point.y - 200)
        let after = CGPoint(
            x: contentLocal.x * result.scale + result.offset.width + 200,
            y: contentLocal.y * result.scale + result.offset.height + 200
        )
        XCTAssertEqual(after.x, point.x, accuracy: 0.001)
        XCTAssertEqual(after.y, point.y, accuracy: 0.001)
    }

    /// Successive pinches must compose. The old viewer read the gesture's
    /// magnitude straight into scale, and since that restarts at 1.0 every
    /// gesture, a second pinch threw the first one's zoom away.
    func test_zoom_composesAcrossSuccessivePinches() {
        let first = geo.zoom(to: 1 * 2, around: CGPoint(x: 200, y: 400), from: .zero, at: 1)
        let second = geo.zoom(to: first.scale * 2, around: CGPoint(x: 200, y: 400),
                              from: first.offset, at: first.scale)
        XCTAssertEqual(second.scale, 4)
    }

    func test_zoom_respectsTheMaximum() {
        let result = geo.zoom(to: 100, around: CGPoint(x: 200, y: 400), from: .zero, at: 1)
        XCTAssertEqual(result.scale, ZoomPanGeometry.maxScale)
    }

    /// Zooming back out to fit must leave the image centred, or it would
    /// sit half off-screen with no way to pan it back.
    func test_zoomOutToFit_recentres() {
        let zoomedIn = geo.zoom(to: 4, around: CGPoint(x: 20, y: 320), from: .zero, at: 1)
        XCTAssertNotEqual(zoomedIn.offset, .zero, "precondition: it panned to the focus")

        let backOut = geo.zoom(to: 1, around: CGPoint(x: 20, y: 320),
                               from: zoomedIn.offset, at: zoomedIn.scale)
        XCTAssertEqual(backOut.scale, 1)
        XCTAssertEqual(backOut.offset, .zero,
                       "at fit scale the clamp must pull the image back to centre")
    }

    // MARK: - Degenerate input

    func test_zoom_withUnmeasuredContent_doesNotProduceNaN() {
        // First frame: the image's fitted size hasn't been measured yet.
        let unmeasured = ZoomPanGeometry(
            containerSize: CGSize(width: 400, height: 800),
            contentSize: .zero
        )
        let result = unmeasured.zoom(to: 2, around: CGPoint(x: 100, y: 100), from: .zero, at: 1)
        XCTAssertEqual(result.scale, 2)
        XCTAssertEqual(result.offset, .zero, "no measured content means no pan range")
    }
}

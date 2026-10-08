import XCTest
import SwiftUI
import CoreGraphics
@testable import MatronDesignSystem

/// The placeholder takes the image's real, aspect-fitted box, so nothing
/// moves when the bytes arrive.
final class AttachmentImageSizeTests: XCTestCase {
    func testTheBoxIsTheImagesAspectFittedInto280() {
        XCTAssertEqual(AttachmentImage.displaySize(for: CGSize(width: 4032, height: 3024)), CGSize(width: 280, height: 210))
        XCTAssertEqual(AttachmentImage.displaySize(for: CGSize(width: 3024, height: 4032)), CGSize(width: 210, height: 280))
        XCTAssertEqual(AttachmentImage.displaySize(for: CGSize(width: 1000, height: 1000)), CGSize(width: 280, height: 280))
        // A small image is drawn at the cap too: `.resizable().scaledToFit()`
        // fills the 280 box, and the reserved box has to match that.
        XCTAssertEqual(AttachmentImage.displaySize(for: CGSize(width: 40, height: 30)), CGSize(width: 280, height: 210))
    }

    func testASliverStaysTappableAndUnknownFallsBack() {
        XCTAssertEqual(AttachmentImage.displaySize(for: CGSize(width: 1, height: 4000)), CGSize(width: 24, height: 280))
        XCTAssertNil(AttachmentImage.displaySize(for: nil))
        XCTAssertNil(AttachmentImage.displaySize(for: CGSize(width: 0, height: 10)))
    }

    /// The box narrows at its ratio: the image's own normally, the floored
    /// box's for a sliver, so neither blows past the cap nor goes untappable.
    func testTheBoxRatioStaysInsideTheCapForSlivers() throws {
        XCTAssertEqual(try XCTUnwrap(AttachmentImage.boxRatio(for: CGSize(width: 1600, height: 900))), 1600.0 / 900.0, accuracy: 1e-9)
        let tall = try XCTUnwrap(AttachmentImage.boxRatio(for: CGSize(width: 1, height: 4000)))
        XCTAssertEqual(24 / tall, 280, accuracy: 0.5, "24 wide → 280 tall, not 96,000")
        let wide = try XCTUnwrap(AttachmentImage.boxRatio(for: CGSize(width: 4000, height: 1)))
        XCTAssertEqual(280 / wide, 24, accuracy: 0.5, "280 wide → 24 tall, still tappable")
        XCTAssertNil(AttachmentImage.boxRatio(for: nil))
    }

    /// On a card narrower than the box (a small phone) the image shrinks to
    /// the card, keeping its aspect ratio, rather than sticking out of it.
    @MainActor
    func testAKnownBoxShrinksToANarrowCard() {
        let narrow = AttachmentImage(image: nil, pixelSize: CGSize(width: 1600, height: 900))
        #if os(macOS)
        let host = NSHostingView(rootView: narrow.frame(width: 200))
        host.layout()
        let size = host.fittingSize
        #else
        let size = UIHostingController(rootView: narrow.frame(width: 200)).sizeThatFits(in: CGSize(width: 200, height: 2000))
        #endif
        XCTAssertEqual(size.width, 200, accuracy: 0.5)
        // 200 wide at 16:9 is 112.5 tall, plus the (absent) meta line.
        XCTAssertEqual(size.height, 112.5, accuracy: 1)
    }
}

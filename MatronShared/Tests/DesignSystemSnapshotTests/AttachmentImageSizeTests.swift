import XCTest
import CoreGraphics
@testable import MatronDesignSystem

/// The placeholder takes the image's real, aspect-fitted box, so nothing
/// moves when the bytes arrive (Dan, 2026-10-01).
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
}

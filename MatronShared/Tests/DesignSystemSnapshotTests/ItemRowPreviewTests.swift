import XCTest
@testable import MatronDesignSystem

/// The row's one-line body preview: built from the start of the body only,
/// so a long report is never typeset whole for one line.
final class ItemRowPreviewTests: XCTestCase {
    func testEmptyBodyHasNoPreview() {
        XCTAssertNil(ItemRow.bodyPreview(""))
    }

    func testShortBodyReadsAsBefore() {
        XCTAssertEqual(ItemRow.bodyPreview("First line\nsecond ![chart](attachment:aa11) line"),
                       "First line second chart line")
    }

    func testLongBodyIsCut() {
        let body = String(repeating: "word ", count: 4000)
        let preview = ItemRow.bodyPreview(body)
        XCTAssertEqual(preview?.count, ItemRow.previewLength)
        XCTAssertTrue(body.hasPrefix(preview ?? "-"))
    }

    func testRefsBeforeTheCutStillShowTheirCaptions() {
        let refs = String(repeating: "![](attachment:aa11)", count: 30)
        let preview = ItemRow.bodyPreview(refs + " and then the text")
        XCTAssertFalse(preview?.contains("attachment:") ?? true)
        XCTAssertTrue(preview?.hasPrefix("(image)(image)") ?? false)
    }
}

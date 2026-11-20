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

    func testABodyStartingWithManyRefsStillFillsThePreview() {
        let refs = String(repeating: "![](attachment:aa11)", count: 120)
        let preview = ItemRow.bodyPreview(refs + " and then the text")
        XCTAssertEqual(preview?.count, ItemRow.previewLength)
        XCTAssertFalse(preview?.contains("attachment:") ?? true)
    }

    func testARepeatedBodyGivesTheSamePreview() {
        let body = "Report\n" + String(repeating: "![](attachment:aa11) line ", count: 200)
        let first = ItemRow.bodyPreview(body)
        XCTAssertEqual(ItemRow.bodyPreview(body), first)
        XCTAssertEqual(ItemRow.bodyPreview(String(body.dropLast()) + "!")?.count, first?.count)
    }

    /// A list lays out and draws each row many times; asking again for the
    /// same body must cost far less than working the preview out.
    func testARepeatedBodyIsCheap() {
        let bodies = (0..<50).map { n in
            "Report \(n)\n" + String(repeating: "![chart](attachment:aa11) a long line of text ", count: 400)
        }
        func time(_ work: () -> Void) -> TimeInterval {
            let start = Date(); work(); return Date().timeIntervalSince(start)
        }
        let cold = time { for body in bodies { _ = ItemRow.bodyPreview(body) } }
        let warm = time { for _ in 0..<10 { for body in bodies { _ = ItemRow.bodyPreview(body) } } } / 10
        print("bodyPreview 50 rows: first \(Int(cold * 1_000_000)) µs, again \(Int(warm * 1_000_000)) µs")
        XCTAssertLessThan(warm, cold / 3)
    }
}

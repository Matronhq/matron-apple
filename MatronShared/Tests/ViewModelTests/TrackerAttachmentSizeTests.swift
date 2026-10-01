import XCTest
import MatronModels

/// The journal stamps an image attachment with its displayed width/height
/// (2026-10-01) so the thread can reserve the image's box before it loads.
final class TrackerAttachmentSizeTests: XCTestCase {
    func testWidthAndHeightParseAndRoundTrip() throws {
        let a = try XCTUnwrap(TrackerAttachment(json: ["blob_ref": "b1", "mime": "image/jpeg", "name": "p.jpg", "size": 10,
                                                       "width": 3024, "height": 4032]))
        XCTAssertEqual(a.pixelSize, CGSize(width: 3024, height: 4032))
        let back = try XCTUnwrap(TrackerAttachment(json: a.json))
        XCTAssertEqual(back, a, "the local cache round-trips the size")
        let decoded = try JSONDecoder().decode(TrackerAttachment.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(decoded.pixelSize, a.pixelSize)
    }

    func testAnOlderJournalOrAnUnsizedImageHasNoSize() throws {
        let old = try XCTUnwrap(TrackerAttachment(json: ["blob_ref": "b1", "mime": "image/png", "name": "p.png", "size": 10]))
        XCTAssertNil(old.pixelSize)
        XCTAssertNil(old.json["width"], "nothing invented on the way back out")
        let zero = TrackerAttachment(blobRef: "b", mime: "image/png", name: "", size: 0, width: 0, height: 10)
        XCTAssertNil(zero.pixelSize)
    }
}

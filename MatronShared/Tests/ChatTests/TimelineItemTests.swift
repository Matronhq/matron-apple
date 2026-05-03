import XCTest
@testable import MatronChat

final class TimelineItemTests: XCTestCase {
    func test_textKind_equality() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        XCTAssertEqual(a, b)
    }

    func test_differentKinds_areInequal() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.file(url: nil, filename: "x", sizeBytes: nil)
        XCTAssertNotEqual(a, b)
    }

    func test_id_isStable() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.id, "evt:1")
    }

    func test_sendState_defaultsToSent() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.sendState, .sent)
    }

    func test_sendState_failed_carriesReason() {
        let a = TimelineItem.SendState.failed(reason: "network")
        let b = TimelineItem.SendState.failed(reason: "network")
        let c = TimelineItem.SendState.failed(reason: "auth")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - prettyJSON()
    //
    // Phase 2 has access to the DTO only — not the raw Matrix event JSON.
    // `prettyJSON()` renders a synthetic JSON-shaped dump of the DTO for the
    // long-press / right-click "View source" sheet (Task 16). Phase 3+ will
    // swap this for the real event JSON via the SDK's
    // `EventTimelineItem.originalJson` accessor.

    func test_prettyJSON_text_includesAllPhase1Fields() {
        let item = TimelineItem(
            id: "$evt:server",
            sender: "@bot:server",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .text(body: "hello", formattedHTML: nil),
            isOwn: false
        )
        let json = item.prettyJSON()
        // The five Phase-1 DTO fields must all appear in the output, so the
        // sheet can serve as a usable diagnostic surface in dev builds.
        XCTAssertTrue(json.contains("\"id\""))
        XCTAssertTrue(json.contains("\"sender\""))
        XCTAssertTrue(json.contains("\"timestamp\""))
        XCTAssertTrue(json.contains("\"kind\""))
        XCTAssertTrue(json.contains("\"isOwn\""))
        XCTAssertTrue(json.contains("\"sendState\""))
        // Field values appear too — copy-paste of the sheet should give a
        // human-readable record of the row.
        XCTAssertTrue(json.contains("$evt:server"))
        XCTAssertTrue(json.contains("@bot:server"))
        XCTAssertTrue(json.contains("hello"))
    }

    func test_prettyJSON_isValidJSON_andRoundTripsThroughJSONSerialization() throws {
        // The view is a JSON-source dump, so the output should be parseable
        // as JSON. If a later edit breaks escaping (e.g. an attachment
        // filename with a quote in it), `JSONSerialization` will fail and
        // this test will catch it before bugbot does.
        let item = TimelineItem(
            id: "$1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "with \"quotes\" and a\nnewline", formattedHTML: nil),
            isOwn: true,
            sendState: .sending
        )
        let json = item.prettyJSON()
        let data = Data(json.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["id"] as? String, "$1")
        XCTAssertEqual(parsed?["sender"] as? String, "@a:s")
        XCTAssertEqual(parsed?["isOwn"] as? Bool, true)
    }

    func test_prettyJSON_imageKind_includesPayload() {
        let item = TimelineItem(
            id: "$2",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .image(url: URL(string: "mxc://server/abc"), caption: "cat", sizeBytes: 12345),
            isOwn: false
        )
        let json = item.prettyJSON()
        XCTAssertTrue(json.contains("image"))
        XCTAssertTrue(json.contains("mxc://server/abc"))
        XCTAssertTrue(json.contains("cat"))
        XCTAssertTrue(json.contains("12345"))
    }

    func test_prettyJSON_fileKind_includesFilename() {
        let item = TimelineItem(
            id: "$3",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .file(url: URL(string: "mxc://server/def"), filename: "report.pdf", sizeBytes: nil),
            isOwn: false
        )
        let json = item.prettyJSON()
        XCTAssertTrue(json.contains("file"))
        XCTAssertTrue(json.contains("report.pdf"))
    }

    func test_prettyJSON_failedSendState_includesReason() {
        let item = TimelineItem(
            id: "$4",
            sender: "@me:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "oops", formattedHTML: nil),
            isOwn: true,
            sendState: .failed(reason: "network")
        )
        let json = item.prettyJSON()
        XCTAssertTrue(json.contains("failed"))
        XCTAssertTrue(json.contains("network"))
    }
}

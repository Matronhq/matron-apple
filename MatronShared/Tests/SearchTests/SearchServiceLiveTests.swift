import XCTest
@testable import MatronSearch

final class SearchServiceLiveTests: XCTestCase {
    var url: URL!
    var svc: SearchServiceLive!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("svc-\(UUID().uuidString).sqlite")
        svc = try SearchServiceLive(databaseURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    func test_indexAndQuery_roundTrip_preservesAllFields() async throws {
        let ts = Date(timeIntervalSince1970: 1_745_000_000)
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: ts, body: "the auth bug is in src/auth.rs")
        let hits = try await svc.query("auth bug", limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].id, "$1")
        XCTAssertEqual(hits[0].roomID, "!r:s")
        XCTAssertEqual(hits[0].sender, "@a:s")
        XCTAssertEqual(hits[0].timestamp.timeIntervalSince1970, ts.timeIntervalSince1970, accuracy: 1.0)
        XCTAssertTrue(hits[0].snippet.contains("<mark>auth"))
    }

    func test_indexIsIdempotent_replaceUpdatesBody() async throws {
        // Re-indexing the same eventID must replace the old row in BOTH messages and
        // messages_fts. This guards against the FTS5 UNINDEXED-DELETE silent no-op.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "first")
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "second")
        let hits = try await svc.query("first", limit: 10)
        XCTAssertEqual(hits.count, 0, "old body must not remain in FTS after re-index")
        let hits2 = try await svc.query("second", limit: 10)
        XCTAssertEqual(hits2.count, 1)
    }

    func test_remove_clearsFTSRow() async throws {
        // Redaction path: `remove(eventID:)` must purge both messages and messages_fts.
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s", timestamp: Date(), body: "secret payload")
        try await svc.remove(eventID: "$1")
        let hits = try await svc.query("secret", limit: 10)
        XCTAssertEqual(hits.count, 0, "redacted event must no longer match in FTS")
        let exists = try await svc.contains(eventID: "$1")
        XCTAssertFalse(exists)
    }

    func test_eventCount_perRoom() async throws {
        try await svc.index(roomID: "!a:s", eventID: "$1", sender: "@x:s", timestamp: Date(), body: "one")
        try await svc.index(roomID: "!a:s", eventID: "$2", sender: "@x:s", timestamp: Date(), body: "two")
        try await svc.index(roomID: "!b:s", eventID: "$3", sender: "@x:s", timestamp: Date(), body: "three")
        let a = try await svc.eventCount(roomID: "!a:s")
        let b = try await svc.eventCount(roomID: "!b:s")
        XCTAssertEqual(a, 2)
        XCTAssertEqual(b, 1)
    }

    func test_recordAndReadBackfill() async throws {
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 100, oldestEventID: "$old", complete: true)
        let done = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertTrue(done)
    }
}

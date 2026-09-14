import XCTest
@testable import MatronSearch

/// `removeAll(eventIDs:)` — the batch form the retention sweep needs. The
/// one-at-a-time `remove(eventID:)` meant one write transaction (and one
/// fsync) per retired row, and a first retention pass retires thousands.
final class SearchRetentionTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        super.setUp()
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func makeService() throws -> SearchServiceLive {
        try SearchServiceLive.open(databaseURL: url)
    }

    func testRemoveAllDropsEveryListedRowAndLeavesTheRest() async throws {
        let service = try makeService()
        for seq in 1...5 {
            try await service.index(roomID: "c1", eventID: String(seq), sender: "agent:dev-2",
                                    timestamp: Date(timeIntervalSince1970: Double(seq)),
                                    body: "body number \(seq)")
        }
        try await service.removeAll(eventIDs: ["2", "4"])

        // `SearchHit.id` IS the event id (MatronShared/Sources/Search/SearchModels.swift:7);
        // there is no `eventID` property on the hit.
        let hits = try await service.query("body", limit: 50)
        XCTAssertEqual(Set(hits.map(\.id)), Set(["1", "3", "5"]))
    }

    func testRemoveAllIgnoresUnknownIDsAndAnEmptyBatch() async throws {
        let service = try makeService()
        try await service.index(roomID: "c1", eventID: "1", sender: "agent:dev-2",
                                timestamp: Date(timeIntervalSince1970: 1), body: "kept")
        try await service.removeAll(eventIDs: [])
        try await service.removeAll(eventIDs: ["nope", "also-nope"])
        let hits = try await service.query("kept", limit: 10)
        XCTAssertEqual(hits.map(\.id), ["1"])
    }

    /// The FTS mirror is an external-content table kept in step by triggers;
    /// a batch delete has to fire them exactly like the single-row form, or
    /// the tokens of the deleted rows are stranded (the 2026-08-06 ghost
    /// corruption). A query that returns exactly the survivors is the
    /// observable proof — the index and the content table agree.
    func testRemoveAllLeavesTheFTSMirrorConsistent() async throws {
        let service = try makeService()
        for seq in 1...200 {
            try await service.index(roomID: "c1", eventID: String(seq), sender: "agent:dev-2",
                                    timestamp: Date(timeIntervalSince1970: Double(seq)),
                                    body: "phrase \(seq)")
        }
        try await service.removeAll(eventIDs: (1...150).map(String.init))
        let hits = try await service.query("phrase", limit: 500)
        XCTAssertEqual(hits.count, 50)
    }

    /// Spec §3.4: "one search write transaction per sweep chunk". The
    /// chunk boundary lives inside `removeAll` — `JournalMaintenance` hands
    /// it the whole list — and `removeAll` opens one `queue.write` per
    /// chunk, so the chunk COUNT is the transaction count. A single
    /// transaction deleting 10^5 rows from an external-content FTS5 table
    /// while holding the index's only connection is the exact shape of the
    /// 2026-08-10 incident `SearchServiceLive` already carries a comment
    /// about.
    func testRemovalChunksAreFiveHundredIDsEach() {
        let ids = (1...1001).map(String.init)
        XCTAssertEqual(SearchServiceLive.removalChunks(of: ids).map(\.count), [500, 500, 1],
                       "1,001 ids must cost three write transactions, not one")
        XCTAssertEqual(SearchServiceLive.removalChunks(of: []).count, 0)
        XCTAssertEqual(SearchServiceLive.removalChunks(of: ids).flatMap { $0 }, ids,
                       "chunking must not drop or reorder ids")
    }

    func testRemoveAllHandlesMoreThanOneChunk() async throws {
        let service = try makeService()
        for seq in 1...600 {
            try await service.index(roomID: "c1", eventID: String(seq), sender: "agent:dev-2",
                                    timestamp: Date(timeIntervalSince1970: Double(seq)),
                                    body: "row \(seq)")
        }
        try await service.removeAll(eventIDs: (1...550).map(String.init))
        let hits = try await service.query("row", limit: 500)
        XCTAssertEqual(hits.count, 50)
    }
}

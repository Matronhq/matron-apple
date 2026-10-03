import GRDB
import XCTest
@testable import MatronJournal
import MatronModels

/// Voice mode's store reads and the `summary` spoken fields (spec
/// 2026-10-03 §1, §3, §5).
final class JournalStoreVoiceTests: XCTestCase {
    private func makeStore() throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: "user:dan")
    }

    private func event(_ seq: Int64, convo: String = "c1", sender: String = "agent:bev",
                       type: String = "text", ts: TimeInterval? = nil,
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: ts ?? Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: summary spoken fields

    func testSummaryDecodesTheSpokenLines() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "Deploy finished", "detail": "All green.", "model": "gpt",
            "spoken": "  The deploy finished. Shall I merge?  ",
            "spoken_more": "Every test passed and the cache was rebuilt.",
            "spoken_ref": "msg_9",
        ])))
        XCTAssertEqual(entry.spoken, "The deploy finished. Shall I merge?")
        XCTAssertEqual(entry.spokenMore, "Every test passed and the cache was rebuilt.")
        XCTAssertEqual(entry.spokenRef, "msg_9")
    }

    /// An old bridge sends none of the keys; a new one omits `spoken_more`
    /// when the model wrote NONE. Null, blank and non-strings read as nil.
    func testAbsentBlankAndNoneReadAsNil() throws {
        let old = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: ["toc": "T", "detail": "D"])))
        XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
        let odd = try XCTUnwrap(SummaryEntryRecord(event: event(6, type: "summary", payload: [
            "toc": "T", "spoken": "   ", "spoken_more": "NONE", "spoken_ref": NSNull(),
        ])))
        XCTAssertNil(odd.spoken); XCTAssertNil(odd.spokenMore); XCTAssertNil(odd.spokenRef)
        let wrong = try XCTUnwrap(SummaryEntryRecord(event: event(7, type: "summary", payload: ["toc": "T", "spoken": 12])))
        XCTAssertNil(wrong.spoken)
    }

    func testSpokenLinesAreCutToTheContractCaps() throws {
        let entry = try XCTUnwrap(SummaryEntryRecord(event: event(5, type: "summary", payload: [
            "toc": "T", "spoken": String(repeating: "a", count: 500), "spoken_more": String(repeating: "b", count: 1_500),
        ])))
        XCTAssertEqual(entry.spoken?.count, 400)
        XCTAssertEqual(entry.spokenMore?.count, 1_200)
    }

    /// The migration is additive: a cache from before it keeps its rows,
    /// which read nil for the three new columns.
    func testSummarySpokenMigratesUpAndOldRowsReadNil() throws {
        let queue = try DatabaseQueue()
        try JournalStore.migrator().migrate(queue, upTo: "event_convo_type")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO summary_entry(convo_id, seq, toc, detail, created_at) VALUES('c1', 4, 'Old', 'row', 1000)
                """)
        }
        try JournalStore.migrator().migrate(queue)
        try queue.read { db in
            let old = try XCTUnwrap(SummaryEntryRecord.fetchOne(db, sql: "SELECT * FROM summary_entry"))
            XCTAssertEqual(old.toc, "Old")
            XCTAssertNil(old.spoken); XCTAssertNil(old.spokenMore); XCTAssertNil(old.spokenRef)
            let columns = try db.columns(in: "summary_entry").map(\.name)
            XCTAssertTrue(columns.contains("spoken")); XCTAssertTrue(columns.contains("spoken_more"))
            XCTAssertTrue(columns.contains("spoken_ref"))
        }
    }

    func testSpokenLinesSurviveTheLiveApplyAndHistoryPaths() throws {
        let store = try makeStore()
        _ = try store.applyJournal(event(2, type: "summary", payload: ["toc": "Live", "spoken": "Live line.", "spoken_ref": "m2"]))
        try store.insertHistory([event(1, type: "summary", payload: ["toc": "Old", "spoken": "Old line."])])
        let entries = try store.summaryEntries(convoID: "c1")
        XCTAssertEqual(entries.map(\.spoken), ["Live line.", "Old line."])
        XCTAssertEqual(entries.first?.spokenRef, "m2")
    }
}

import XCTest
@testable import MatronJournal
import MatronModels

/// The store reports its own observation fetches and hot writes, so a
/// running app can measure where the store's time goes.
final class JournalStoreMetricsTests: XCTestCase {
    private func event(_ seq: Int64, convo: String = "c1") -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: "agent:box-a", type: "text",
                     payloadData: try! JSONSerialization.data(withJSONObject: ["body": "hi"]))
    }

    func testAJournalFrameCountsItsCommitAndTheConversationsRefetch() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        var conversations = store.conversationsStream().makeAsyncIterator()
        _ = await conversations.next()
        _ = metrics.drain()
        try store.applyJournal(event(1))
        _ = await conversations.next()
        let report = metrics.drain()
        XCTAssertEqual(report.writes.first { $0.name == "applyJournal" }?.commits, 1)
        let refetch = try XCTUnwrap(report.observations.first { $0.name == "conversationsStream" })
        XCTAssertEqual(refetch.fires, 1)
        XCTAssertEqual(refetch.rows, 1)
    }

    func testItemsStreamScopesAreReportedSeparately() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        var all = store.itemsStream(scope: .all).makeAsyncIterator()
        var convo = store.itemsStream(scope: .convo("c1")).makeAsyncIterator()
        _ = await all.next(); _ = await convo.next()
        let names = Set(metrics.drain().observations.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["itemsStream.all", "itemsStream.convo"]), "\(names)")
    }

    func testItemWritesAreCountedUnderTheirOwnNames() throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.upsertItems([TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")])
        try store.replaceComments(itemID: "i1", [])
        let names = metrics.drain().writes.map(\.name)
        XCTAssertTrue(Set(names).isSuperset(of: ["upsertItems", "replaceComments"]), "\(names)")
    }
}

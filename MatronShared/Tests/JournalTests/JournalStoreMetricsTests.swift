import XCTest
@testable import MatronJournal
import MatronModels

/// The store reports its own observation fetches and hot writes, so a
/// running app can measure where the store's time goes.
final class JournalStoreMetricsTests: XCTestCase {
    private func event(_ seq: Int64, convo: String = "c1", type: String = "text",
                       payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)),
                     sender: "agent:box-a", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// Observation fetches run on the writer inside the commit, so by the
    /// time a write returns, every observer it invalidated has fetched.
    private func firesCaused(by metrics: StoreMetrics, _ write: () throws -> Void) rethrows -> [String: Int] {
        _ = metrics.drain()
        try write()
        return Dictionary(uniqueKeysWithValues: metrics.drain().observations.map { ($0.name, $0.fires) })
    }

    /// A message leaves `session_state` alone, so the whole-table
    /// session-state map must not be re-read for it.
    func testAMessageDoesNotRefetchTheSessionStateMap() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.applyJournal(event(1))
        var states = store.sessionStatesStream().makeAsyncIterator()
        var conversations = store.conversationsStream().makeAsyncIterator()
        _ = await states.next(); _ = await conversations.next()
        let fires = try firesCaused(by: metrics) { _ = try store.applyJournal(event(2)) }
        XCTAssertEqual(fires["conversationsStream"], 1, "the snippet changed: \(fires)")
        XCTAssertNil(fires["sessionStatesStream"], "\(fires)")
    }

    func testASessionStatusChangeStillRefetchesTheSessionStateMap() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.applyJournal(event(1))
        var states = store.sessionStatesStream().makeAsyncIterator()
        _ = await states.next()
        let fires = try firesCaused(by: metrics) {
            _ = try store.applyJournal(event(2, type: JournalEventType.sessionStatus, payload: ["state": "waiting"]))
        }
        XCTAssertEqual(fires["sessionStatesStream"], 1, "\(fires)")
        let updated = await states.next()
        XCTAssertEqual(updated?["c1"], "waiting")
    }

    /// The item poll re-sends every item; one that has not changed must not
    /// make the item observations re-read the table.
    func testUpsertingAnUnchangedItemRefetchesNothing() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        let item = TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")
        try store.upsertItems([item])
        var all = store.itemsStream(scope: .all).makeAsyncIterator()
        _ = await all.next()
        let fires = try firesCaused(by: metrics) { try store.upsertItems([item]) }
        XCTAssertNil(fires["itemsStream.all"], "\(fires)")
    }

    func testUpsertingAChangedItemStillRefetches() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.upsertItems([TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")])
        var all = store.itemsStream(scope: .all).makeAsyncIterator()
        _ = await all.next()
        let renamed = TrackerItem(id: "i1", num: 1, kind: .task, title: "renamed", originConvoID: "c1")
        let fires = try firesCaused(by: metrics) { try store.upsertItems([renamed]) }
        XCTAssertEqual(fires["itemsStream.all"], 1, "\(fires)")
        let updated = await all.next()
        XCTAssertEqual(updated?.first?.title, "renamed")
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

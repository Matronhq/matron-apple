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

    /// On a queue (these stores are in memory), the change feed reads a
    /// commit's rows back on the writer inside the commit, so by the time a
    /// write returns, that read has been counted.
    private func firesCaused(by metrics: StoreMetrics, _ write: () throws -> Void) rethrows -> [String: Int] {
        _ = metrics.drain()
        try write()
        return Dictionary(uniqueKeysWithValues: metrics.drain().observations.map { ($0.name, $0.fires) })
    }

    /// The item poll re-sends every item; one that has not changed writes
    /// no row, so the change feed reads nothing back for it.
    func testUpsertingAnUnchangedItemRefetchesNothing() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        let item = TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")
        try store.upsertItems([item])
        var all = store.itemSectionsStream(scope: .all).makeAsyncIterator()
        _ = await all.next()
        let fires = try firesCaused(by: metrics) { try store.upsertItems([item]) }
        XCTAssertNil(fires["storeChangeFeed"], "\(fires)")
    }

    func testUpsertingAChangedItemStillRefetches() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.upsertItems([TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")])
        var all = store.itemSectionsStream(scope: .all).makeAsyncIterator()
        _ = await all.next()
        let renamed = TrackerItem(id: "i1", num: 1, kind: .task, title: "renamed", originConvoID: "c1")
        let fires = try firesCaused(by: metrics) { try store.upsertItems([renamed]) }
        XCTAssertEqual(fires["storeChangeFeed"], 1, "\(fires)")
        let updated = await all.next()
        XCTAssertEqual(updated?.tasks.first?.title, "renamed")
    }

    /// A journal frame is one commit, and the chat list reads back only the
    /// one conversation row it changed.
    func testAJournalFrameCountsItsCommitAndTheConversationRowReadBack() async throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        var conversations = store.conversationsStream().makeAsyncIterator()
        _ = await conversations.next()
        _ = metrics.drain()
        try store.applyJournal(event(1))
        _ = await conversations.next()
        let report = metrics.drain()
        XCTAssertEqual(report.writes.first { $0.name == "applyJournal" }?.commits, 1)
        let readBack = try XCTUnwrap(report.observations.first { $0.name == "storeChangeFeed" })
        XCTAssertEqual(readBack.fires, 1)
        XCTAssertEqual(readBack.rows, 1)
    }

    func testItemWritesAreCountedUnderTheirOwnNames() throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.upsertItems([TrackerItem(id: "i1", num: 1, kind: .task, title: "t", originConvoID: "c1")])
        try store.replaceComments(itemID: "i1", [])
        let names = metrics.drain().writes.map(\.name)
        XCTAssertTrue(Set(names).isSuperset(of: ["upsertItems", "replaceComments"]), "\(names)")
    }

    /// The list refreshes hold the writer for their sweep, so they are timed
    /// like every other write (a slow one used to be invisible in the report).
    func testListRefreshWritesAreCountedUnderTheirOwnNames() throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.replaceMissions([])
        try store.replaceProjects([])
        let names = metrics.drain().writes.map(\.name)
        XCTAssertTrue(Set(names).isSuperset(of: ["replaceMissions", "replaceProjects"]), "\(names)")
    }

    /// Every write is timed, so a long hold on the writer always shows up
    /// under a name: the tool-output sweep and the milestone refresh held
    /// it untimed before.
    func testMaintenanceAndMilestoneWritesAreCounted() throws {
        let metrics = StoreMetrics()
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", metrics: metrics)
        try store.purgeExpiredToolOutputSnippets(now: Date())
        try store.replaceMilestones(missionID: "m1", [])
        let names = metrics.drain().writes.map(\.name)
        XCTAssertTrue(Set(names).isSuperset(of: ["sweepTombstones", "replaceMilestones"]), "\(names)")
    }
}

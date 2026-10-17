import GRDB
import MatronModels
import os
import XCTest
@testable import MatronJournal

/// `ItemsIndex`: every item row, kept current from the change feed, with
/// its lists kept in order as rows change, serving the needs-you counts
/// and the needs-you items per mission with exactly the values today's
/// fetches return. The For you sections are held to
/// `ItemsPanelViewModel.sections(from:)` in `ItemsIndexSectionsTests`.
class ItemsIndexTests: XCTestCase {
    /// `ItemsIndexPoolTests` runs the whole suite again on a pool.
    class var writerKind: StoreWriterKind { .queue }

    private func makeStore(usesChangeFeed: Bool = true) throws -> JournalStore {
        try makeTestStore(Self.writerKind, metrics: StoreMetrics(), usesChangeFeed: usesChangeFeed)
    }

    private func item(_ id: String, num: Int, kind: ItemKind = .task, state: ItemState = .open,
                      awaiting: ItemAwaiting? = .agent, rank: Double = 1024, title: String? = nil,
                      origin: String = "c1", mission: String? = nil, updated: TimeInterval = 1_900_000_000,
                      input: TimeInterval? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: kind, state: state, resolution: state == .closed ? .done : nil,
                    awaiting: awaiting, rank: rank, title: title ?? "Item \(num)", originConvoID: origin,
                    createdAt: Date(timeIntervalSince1970: 1_900_000_000),
                    updatedAt: Date(timeIntervalSince1970: updated),
                    closedAt: state == .closed ? Date(timeIntervalSince1970: updated) : nil,
                    missionID: mission, lastUserInputAt: input.map { Date(timeIntervalSince1970: $0) })
    }

    /// An index state fed synchronously by the change feed: events arrive
    /// on the writer inside each commit, so it is current when the write
    /// call returns.
    private final class FedState: @unchecked Sendable {
        private let lock = NSLock()
        private var _state = ItemsIndexState()
        private var _touched: [ItemsIndexState.Touched?] = []
        var state: ItemsIndexState { lock.withLock { _state } }
        /// What each event touched, `nil` for a snapshot.
        var touched: [ItemsIndexState.Touched?] { lock.withLock { _touched } }
        func handle(_ event: StoreFeedEvent<[(Int64, ItemRecord)]>) {
            lock.withLock { _touched.append(_state.apply(event)) }
        }
    }

    private func feedState(_ store: JournalStore) throws -> (FedState, StoreChangeFeed.Subscription) {
        let fed = FedState()
        let subscription = store.observeChanges(
            tables: .item,
            snapshot: { db in try StoreChangeFeed.itemRows(db) },
            onEvent: fed.handle, onError: { XCTFail("feed error: \($0)") })
        try store.db.writeWithoutTransaction { _ in }
        return (fed, subscription)
    }

    /// Today's fetches, from a fresh read.
    private func fresh(_ store: JournalStore) throws
        -> (counts: [String: Int], byMission: [String: [TrackerItem]], byOrigin: [String: [TrackerItem]]) {
        let items = try store.items(scope: .all)
        return (try store.needsUserCounts(), try store.needsYouItemsByMission(),
                Dictionary(grouping: items.filter { $0.kind == .task && $0.state == .open }, by: \.originConvoID))
    }

    // MARK: The gate

    /// After every commit of a seeded random sequence of real item writes,
    /// the index's needs-you counts and needs-you items per mission equal
    /// today's fetches from a fresh read, and its open tasks per origin
    /// equal that conversation's items in the store's order.
    func testCountsMissionsAndOriginsEqualTodaysFetchesAfterEveryCommit() throws {
        for seed in UInt64(1)...6 {
            let store = try makeStore(usesChangeFeed: false)
            var writes = RandomItemWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let (fed, subscription) = try feedState(store)
            defer { subscription.cancel() }
            var sawMissionTies = false, sawSeveralCounts = false
            for step in 0..<400 {
                let what = try writes.step()
                let state = fed.state
                let expected = try fresh(store)
                let context = "seed \(seed) step \(step) (\(what))"
                guard state.needsUserCounts == expected.counts else {
                    return XCTFail("\(context): counts \(state.needsUserCounts) != \(expected.counts)")
                }
                guard state.needsYouByMission == expected.byMission else {
                    return XCTFail("\(context): needs-you by mission diverged")
                }
                guard state.tasksByOrigin == expected.byOrigin else {
                    return XCTFail("\(context): open tasks by origin diverged")
                }
                XCTAssertEqual(state.count, try store.items(scope: .all).count, context)
                sawMissionTies = sawMissionTies || expected.byMission.values.contains { list in
                    zip(list, list.dropFirst()).contains { $0.updatedAt == $1.updatedAt }
                }
                sawSeveralCounts = sawSeveralCounts || expected.counts.count > 1
            }
            XCTAssertTrue(sawMissionTies, "seed \(seed): ties on activity within a mission")
            XCTAssertTrue(sawSeveralCounts, "seed \(seed): needs-you items in several conversations")
            XCTAssertGreaterThan(fed.state.rebuilds, 0)
        }
    }

    /// The gate again, through the live index and the public streams: with
    /// the flag on, after every commit the counts and mission streams'
    /// latest values equal today's fetches, and the sections stream's
    /// needs-you list holds exactly the open items awaiting the user.
    func testLiveIndexStreamsEqualTodaysFetchesAfterEveryCommit() async throws {
        for seed in UInt64(1)...3 {
            let store = try makeStore()
            var writes = RandomItemWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let counts = Latest<[String: Int]>()
            let byMission = Latest<[String: [TrackerItem]]>()
            let sections = Latest<ItemsIndexSections>()
            let consumers = [
                counts.consume(store.needsUserCountsStream()),
                byMission.consume(store.needsYouItemsByMissionStream()),
                sections.consume(store.itemSectionsStream()),
            ]
            defer { consumers.forEach { $0.cancel() } }

            for step in 0..<250 {
                let what = try writes.step()
                store.itemsIndex.waitUntilIdle()
                await MainActor.run {}
                let expected = try fresh(store)
                let awaiting = Set(try store.items(scope: .all).filter(\.needsUser).map(\.id))
                let delivered = await settle {
                    counts.value == expected.counts && byMission.value == expected.byMission
                        && sections.value.map { Set($0.needsYou.map(\.id)) } == awaiting
                }
                guard delivered else {
                    return XCTFail("seed \(seed) step \(step) (\(what)): stale streams")
                }
            }
        }
    }

    private func settle(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    // MARK: Touching only what changed

    /// Thirty items in every section, then one write at a time: each
    /// touches only the lists its item was or is in, and every other
    /// section keeps the very storage it had.
    func testASingleItemWriteTouchesOnlyItsSections() throws {
        let store = try makeStore(usesChangeFeed: false)
        var items: [TrackerItem] = []
        for n in 1...30 {
            switch n % 5 {
            case 0: items.append(item("t\(n)", num: n, origin: n % 2 == 0 ? "c1" : "c2"))
            case 1: items.append(item("q\(n)", num: n, kind: .question, awaiting: .user, mission: "m1"))
            case 2: items.append(item("d\(n)", num: n, kind: .decision, awaiting: nil))
            case 3: items.append(item("x\(n)", num: n, state: .closed, awaiting: nil))
            default: items.append(item("a\(n)", num: n, kind: .question, state: .closed, awaiting: nil))
            }
        }
        try store.upsertItems(items)
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }
        let before = fed.state.sections

        // A task renamed: its task lists only.
        try store.upsertItems([item("t10", num: 10, title: "Renamed", updated: 1_900_000_001)])
        XCTAssertEqual(fed.touched.last, ItemsIndexState.Touched(lists: [.tasks], origins: ["c1"]))
        let afterRename = fed.state.sections
        XCTAssertEqual(afterRename.tasks.first { $0.id == "t10" }?.title, "Renamed")
        XCTAssertTrue(sameStorage(afterRename.needsYou, before.needsYou))
        XCTAssertTrue(sameStorage(afterRename.decisions, before.decisions))
        XCTAssertTrue(sameStorage(afterRename.done, before.done))
        XCTAssertTrue(sameStorage(afterRename.decided, before.decided))
        XCTAssertFalse(sameStorage(afterRename.tasks, before.tasks))

        // A question answered: out of needs-you and its mission, onto the
        // Done tab, and the counts change; tasks and decisions untouched.
        try store.upsertItems([item("q11", num: 11, kind: .question, awaiting: .agent, mission: "m1",
                                    updated: 1_900_000_002, input: 1_900_000_002)])
        XCTAssertEqual(fed.touched.last, ItemsIndexState.Touched(lists: [.needsYou, .decided], needsUserCounts: true,
                                                                 missions: ["m1"]))
        let afterAnswer = fed.state.sections
        XCTAssertEqual(afterAnswer.decided.first?.id, "q11", "the user's answer puts it on top")
        XCTAssertFalse(afterAnswer.needsYou.contains { $0.id == "q11" })
        XCTAssertTrue(sameStorage(afterAnswer.tasks, afterRename.tasks))
        XCTAssertTrue(sameStorage(afterAnswer.decisions, afterRename.decisions))
        XCTAssertTrue(sameStorage(afterAnswer.done, afterRename.done))
        XCTAssertEqual(fed.state.needsUserCounts["c1"], 5)
        XCTAssertEqual(fed.state.needsYouByMission["m1"]?.count, 5)

        // A write that changes nothing an item shows commits no change, and
        // a conversation write reaches no item reader.
        let events = fed.touched.count
        try store.upsertItems([item("q11", num: 11, kind: .question, awaiting: .agent, mission: "m1",
                                    updated: 1_900_000_002, input: 1_900_000_002)])
        try store.ensureConversation(id: "c1", title: "C1")
        XCTAssertEqual(fed.touched.count, events)
        XCTAssertEqual(fed.state.rebuilds, 1, "only the load sorted from scratch")
    }

    private func sameStorage(_ a: [TrackerItem], _ b: [TrackerItem]) -> Bool {
        a.withUnsafeBufferPointer { x in b.withUnsafeBufferPointer { y in x.baseAddress == y.baseAddress } }
    }

    /// A commit changing a large share of the items sorts the lists once
    /// instead of moving each item; small commits stay incremental. Either
    /// way the lists are the store's.
    func testALargeCommitRebuildsOnceAndMatchesTheStore() throws {
        let store = try makeStore(usesChangeFeed: false)
        try store.upsertItems((1...400).map { item("t\($0)", num: $0, rank: Double($0 % 7), origin: "c\($0 % 3)") })
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }
        XCTAssertEqual(fed.state.rebuilds, 1, "the snapshot load")

        try store.upsertItems((1...300).map {
            item("t\($0)", num: $0, rank: Double($0 % 5), origin: "c\($0 % 3)", updated: 1_900_000_001)
        })
        XCTAssertEqual(fed.state.rebuilds, 2, "one rebuild for the large commit")
        XCTAssertEqual(fed.state.tasksByOrigin, try fresh(store).byOrigin)
        XCTAssertEqual(fed.state.sections.tasks, try store.items(scope: .all))

        try store.upsertItems([item("t1", num: 1, rank: -1, origin: "c1", updated: 1_900_000_002)])
        XCTAssertEqual(fed.state.rebuilds, 2, "a small commit keeps the order incrementally")
        XCTAssertEqual(fed.state.sections.tasks, try store.items(scope: .all))
    }

    /// Delete-then-insert in one transaction can hand an item's rowid to
    /// another item, or move an item to a new rowid. Either way the index
    /// ends up holding exactly the table's items.
    func testRowidReuseAndAMovedKeyLeaveExactlyTheTablesItems() throws {
        let store = try makeStore(usesChangeFeed: false)
        try store.upsertItems([item("a", num: 1), item("b", num: 2, kind: .question, awaiting: .user)])
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }

        try store.db.write { db in
            // "b" holds the highest rowid, so "c" reuses it; "a" comes back
            // on a new rowid.
            try db.execute(sql: "DELETE FROM item WHERE id IN ('a', 'b')")
            try ItemRecord(item("c", num: 3)).insert(db)
            try ItemRecord(item("a", num: 1, title: "A again")).insert(db)
        }

        let state = fed.state
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.sections.tasks, try store.items(scope: .all))
        XCTAssertEqual(state.needsUserCounts, [:])
        XCTAssertEqual(state.sections.needsYou, [])
    }

    // MARK: Streams in index mode

    func testIndexModeStreamsDeliverOnTheMainQueue() async throws {
        let store = try makeStore()
        try store.upsertItems([item("q", num: 1, kind: .question, awaiting: .user)])
        let offMain = OSAllocatedUnfairLock(initialState: 0)
        let values = OSAllocatedUnfairLock(initialState: [[String]]())
        let token = store.itemsIndex.observeSections { sections in
            if !Thread.isMainThread { offMain.withLock { $0 += 1 } }
            values.withLock { $0.append(sections.needsYou.map(\.id)) }
        }
        defer { token.cancel() }
        try await waitUntil { values.withLock { $0.count } == 1 }
        try store.upsertItems([item("r", num: 2, kind: .question, awaiting: .user, updated: 1_900_000_001)])
        try await waitUntil { values.withLock { $0.count } == 2 }
        XCTAssertEqual(values.withLock { $0 }, [["q"], ["r", "q"]])
        XCTAssertEqual(offMain.withLock { $0 }, 0, "every delivery lands on the main queue")
    }

    /// One shared index per store, started by the first subscriber, on one
    /// feed subscription to the items alone however many streams are open.
    func testOneIndexPerStoreStartedByTheFirstSubscriber() async throws {
        let store = try makeStore()
        try store.upsertItems([item("q", num: 1, kind: .question, awaiting: .user, mission: "m1")])
        XCTAssertEqual(store.changeFeed.subscriberCount, 0, "nothing runs before a stream is opened")

        var counts = store.needsUserCountsStream().makeAsyncIterator()
        var byMission = store.needsYouItemsByMissionStream().makeAsyncIterator()
        var sections = store.itemSectionsStream().makeAsyncIterator()
        let firstCounts = await counts.next()
        let firstByMission = await byMission.next()
        let firstSections = await sections.next()
        XCTAssertEqual(firstCounts, ["c1": 1])
        XCTAssertEqual(firstByMission?.mapValues { $0.map(\.id) }, ["m1": ["q"]])
        XCTAssertEqual(firstSections?.needsYou.map(\.id), ["q"])
        XCTAssertEqual(store.changeFeed.subscriberCount, 1)
        XCTAssertNil(store.startedConversationIndex, "the conversation index is not started by item streams")
    }

    /// Releasing the store releases its index, and every stream it was
    /// serving finishes.
    func testStreamsFinishWhenTheStoreIsReleased() async throws {
        var store: JournalStore? = try makeStore()
        try store?.upsertItems([item("q", num: 1, kind: .question, awaiting: .user)])
        let counts = Latest<[String: Int]>()
        let byMission = Latest<[String: [TrackerItem]]>()
        let sections = Latest<ItemsIndexSections>()
        let consumers = [
            counts.consume(try XCTUnwrap(store).needsUserCountsStream()),
            byMission.consume(try XCTUnwrap(store).needsYouItemsByMissionStream()),
            sections.consume(try XCTUnwrap(store).itemSectionsStream()),
        ]
        defer { consumers.forEach { $0.cancel() } }
        try await waitUntil { counts.value != nil && byMission.value != nil && sections.value != nil }
        weak var index = store?.startedItemsIndex
        XCTAssertNotNil(index)

        store = nil

        try await waitUntil { counts.finished && byMission.finished && sections.finished }
        XCTAssertNil(index, "the index goes with its store")
    }

    /// The flag off leaves the store exactly as before: no index, no feed
    /// subscriber, the value observations.
    func testFlagOffServesTheValueObservations() async throws {
        let store = try makeStore(usesChangeFeed: false)
        try store.upsertItems([item("q", num: 1, kind: .question, awaiting: .user, mission: "m1")])
        var counts = store.needsUserCountsStream().makeAsyncIterator()
        var byMission = store.needsYouItemsByMissionStream().makeAsyncIterator()
        let firstCounts = await counts.next()
        let firstByMission = await byMission.next()
        XCTAssertEqual(firstCounts, ["c1": 1])
        XCTAssertEqual(firstByMission?.mapValues { $0.map(\.id) }, ["m1": ["q"]])
        XCTAssertEqual(store.changeFeed.subscriberCount, 0)
        XCTAssertNil(store.startedItemsIndex)
    }

    /// Each projection delivers only when its own value changes: a renamed
    /// task changes the sections, not the counts or the missions.
    func testIndexModeProjectionsDeliverOnlyTheirOwnChanges() async throws {
        let store = try makeStore()
        try store.upsertItems([item("t", num: 1), item("q", num: 2, kind: .question, awaiting: .user, mission: "m1")])
        let sections = OSAllocatedUnfairLock(initialState: 0)
        let counts = OSAllocatedUnfairLock(initialState: 0)
        let missions = OSAllocatedUnfairLock(initialState: 0)
        let index = store.itemsIndex
        let tokens = [
            index.observeSections { _ in sections.withLock { $0 += 1 } },
            index.observeNeedsUserCounts { _ in counts.withLock { $0 += 1 } },
            index.observeNeedsYouByMission { _ in missions.withLock { $0 += 1 } },
        ]
        defer { tokens.forEach { $0.cancel() } }
        try await waitUntil { sections.withLock { $0 } == 1 && counts.withLock { $0 } == 1 && missions.withLock { $0 } == 1 }

        try store.upsertItems([item("t", num: 1, title: "Renamed", updated: 1_900_000_001)])
        try await waitUntil { sections.withLock { $0 } == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(counts.withLock { $0 }, 1)
        XCTAssertEqual(missions.withLock { $0 }, 1)

        try store.upsertItems([item("q", num: 2, kind: .question, awaiting: .agent, mission: "m1", updated: 1_900_000_001)])
        try await waitUntil { counts.withLock { $0 } == 2 && missions.withLock { $0 } == 2 }
        XCTAssertEqual(sections.withLock { $0 }, 3)
    }

    /// `wipeItems()` and `wipe()` reset the index: it reloads from a fresh
    /// snapshot, and goes on from there.
    func testWipesReloadTheIndex() async throws {
        let store = try makeStore()
        try store.upsertItems([item("q", num: 1, kind: .question, awaiting: .user)])
        var iterator = store.itemSectionsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.needsYou.map(\.id), ["q"])

        try store.wipeItems()
        let wiped = await iterator.next()
        XCTAssertEqual(wiped, ItemsIndexSections())

        try store.upsertItems([item("r", num: 2, kind: .question, awaiting: .user)])
        let refilled = await iterator.next()
        XCTAssertEqual(refilled?.needsYou.map(\.id), ["r"])

        try store.wipe()
        let wipedAgain = await iterator.next()
        XCTAssertEqual(wipedAgain, ItemsIndexSections())
    }
}

final class ItemsIndexPoolTests: ItemsIndexTests {
    override class var writerKind: StoreWriterKind { .pool }
}

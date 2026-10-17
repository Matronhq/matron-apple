import GRDB
import MatronModels
import os
import XCTest
@testable import MatronJournal

/// `ItemsIndex`: every item row, kept current from the change feed, with
/// its lists kept in order as rows change, serving the needs-you counts,
/// the mission and the project item lists with exactly the values today's
/// fetches return. The panel sections, app-wide and per conversation, are
/// held to `ItemsPanelViewModel.sections(from:)` in `ItemsIndexSectionsTests`.
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

    /// The projects the random missions are filed in.
    static let projects = ["p1": ["m1", "m2"], "p2": ["m3"]]

    /// Files `RandomItemWrites`' missions into two projects, again after a
    /// `wipe()` has cleared the mission cache.
    private func seedMissions(_ store: JournalStore) throws {
        guard try store.db.read({ db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mission") ?? 0 }) == 0 else { return }
        try store.upsertMissions(Self.projects.flatMap { project, missions in
            missions.map { Mission(id: $0, num: Int($0.dropFirst())!, title: $0, originConvoID: "c1", projectID: project) }
        })
    }

    /// Today's fetches, from a fresh read.
    private struct Fresh {
        var counts: [String: Int]
        var byMission: [String: [TrackerItem]]
        var tasksByOrigin: [String: [TrackerItem]]
        var missionOpen: [String: [TrackerItem]]
        var missionClosed: [String: [TrackerItem]]
        var missionClosedCount: [String: Int]
        var projectMissions: [String: Set<String>]
        var projectNeedsYou: [String: [TrackerItem]]
        var projectOpen: [String: [TrackerItem]]
    }

    private func fresh(_ store: JournalStore) throws -> Fresh {
        let items = try store.items(scope: .all)
        let missions = RandomItemWrites.missions
        let counts = try store.needsUserCounts(), byMission = try store.needsYouItemsByMission()
        return try store.db.read { db in
            Fresh(
                counts: counts, byMission: byMission,
                tasksByOrigin: Dictionary(grouping: items.filter { $0.kind == .task && $0.state == .open }, by: \.originConvoID),
                missionOpen: Dictionary(uniqueKeysWithValues: try missions.map {
                    ($0, try JournalStore.missionItemsRequest($0).fetchAll(db).map(\.item))
                }),
                missionClosed: Dictionary(uniqueKeysWithValues: try missions.map {
                    ($0, try JournalStore.missionClosedItemsRequest($0, limit: 5).fetchAll(db).map(\.item))
                }),
                missionClosedCount: Dictionary(uniqueKeysWithValues: try missions.map {
                    ($0, try JournalStore.missionClosedItemsCount(db, $0))
                }),
                projectMissions: Dictionary(uniqueKeysWithValues: try Self.projects.keys.map { project in
                    (project, Set(try String.fetchAll(db, sql: "SELECT id FROM mission WHERE project_id = ?", arguments: [project])))
                }),
                projectNeedsYou: Dictionary(uniqueKeysWithValues: try Self.projects.keys.map {
                    ($0, try JournalStore.projectNeedsYouItems(db, $0))
                }),
                projectOpen: Dictionary(uniqueKeysWithValues: try Self.projects.keys.map {
                    ($0, try JournalStore.projectOpenItems(db, $0))
                }))
        }
    }

    // MARK: The gate

    /// After every commit of a seeded random sequence of real item writes,
    /// each of the index's projections equals today's fetch from a fresh
    /// read: the needs-you counts, the needs-you items per mission, each
    /// mission's open items, closed items and closed count, each project's
    /// needs-you and open items (over the project's missions as the
    /// `mission` table has them), and each conversation's open tasks in
    /// the store's order.
    func testEveryProjectionEqualsTodaysFetchesAfterEveryCommit() throws {
        for seed in UInt64(1)...6 {
            let store = try makeStore(usesChangeFeed: false)
            try seedMissions(store)
            var writes = RandomItemWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            try seedMissions(store)
            let (fed, subscription) = try feedState(store)
            defer { subscription.cancel() }
            var sawMissionTies = false, sawSeveralCounts = false, sawTiers = false, sawProjectMerge = false
            for step in 0..<400 {
                let what = try writes.step()
                try seedMissions(store)
                let state = fed.state
                let expected = try fresh(store)
                let context = "seed \(seed) step \(step) (\(what))"
                guard state.needsUserCounts == expected.counts else {
                    return XCTFail("\(context): counts \(state.needsUserCounts) != \(expected.counts)")
                }
                guard state.needsYouByMission == expected.byMission else {
                    return XCTFail("\(context): needs-you by mission diverged")
                }
                let tasksByOrigin = state.slices.compactMapValues { $0.tasks.isEmpty ? nil : $0.tasks }
                guard tasksByOrigin == expected.tasksByOrigin else {
                    return XCTFail("\(context): open tasks by origin diverged")
                }
                for mission in RandomItemWrites.missions {
                    guard state.openItems(missionID: mission) == expected.missionOpen[mission],
                          state.closedItems(missionID: mission, limit: 5) == expected.missionClosed[mission],
                          state.closedItemsCount(missionID: mission) == expected.missionClosedCount[mission]
                    else { return XCTFail("\(context): items of mission \(mission) diverged") }
                }
                for project in Self.projects.keys {
                    let missions = expected.projectMissions[project] ?? []
                    guard state.needsYouItems(missionIDs: missions) == expected.projectNeedsYou[project],
                          state.openItems(missionIDs: missions) == expected.projectOpen[project]
                    else { return XCTFail("\(context): items of project \(project) diverged") }
                }
                sawTiers = sawTiers || expected.missionOpen.values.contains { list in
                    Set(list.map { $0.awaiting?.rawValue ?? "none" }).count == 3
                }
                sawProjectMerge = sawProjectMerge || Set(expected.projectOpen["p1"]?.compactMap(\.missionID) ?? []).count == 2
                XCTAssertEqual(state.count, try store.items(scope: .all).count, context)
                sawMissionTies = sawMissionTies || expected.byMission.values.contains { list in
                    zip(list, list.dropFirst()).contains { $0.updatedAt == $1.updatedAt }
                }
                sawSeveralCounts = sawSeveralCounts || expected.counts.count > 1
            }
            XCTAssertTrue(sawMissionTies, "seed \(seed): ties on activity within a mission")
            XCTAssertTrue(sawSeveralCounts, "seed \(seed): needs-you items in several conversations")
            XCTAssertTrue(sawTiers, "seed \(seed): a mission with items awaiting the user, an agent and no one")
            XCTAssertTrue(sawProjectMerge, "seed \(seed): a project's list drawn from two missions")
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
            let conversation = Latest<ItemsIndexSections>()
            let mission = Latest<[TrackerItem]>()
            let consumers = [
                counts.consume(store.needsUserCountsStream()),
                byMission.consume(store.needsYouItemsByMissionStream()),
                sections.consume(store.itemSectionsStream(scope: .all)),
                conversation.consume(store.itemSectionsStream(scope: .convo("c1"))),
                mission.consume(store.itemsStream(missionID: "m1")),
            ]
            defer { consumers.forEach { $0.cancel() } }

            for step in 0..<250 {
                let what = try writes.step()
                store.itemsIndex.waitUntilIdle()
                await MainActor.run {}
                let expected = try fresh(store)
                let awaiting = Set(try store.items(scope: .all).filter(\.needsUser).map(\.id))
                let missionOpen = try fresh(store).missionOpen["m1"]
                let delivered = await settle {
                    counts.value == expected.counts && byMission.value == expected.byMission
                        && sections.value.map { Set($0.needsYou.map(\.id)) } == awaiting
                        && conversation.value?.tasks ?? [] == expected.tasksByOrigin["c1"] ?? []
                        && mission.value == missionOpen
                }
                guard delivered else {
                    return XCTFail("seed \(seed) step \(step) (\(what)): stale streams")
                }
            }
        }
    }

    /// The For you list's `ListUpdate`s, applied in the order they
    /// arrive, reproduce the index's `needsYou` and `decided` sections
    /// after every commit of a random write sequence (wipes included), and
    /// each update's rows are those sections' items in that order. Answers
    /// move rows between the two sections.
    func testForYouUpdatesAppliedInOrderReproduceTheSections() async throws {
        var edits = 0, moves = 0, crossSection = 0, inserts = 0, removes = 0, reconfigures = 0
        for seed in UInt64(1)...3 {
            let store = try makeStore()
            var writes = RandomItemWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let log = PublicationLog<TrackerItem>()
            let token = store.itemsIndex.observeForYouUpdates(log.append)
            defer { token.cancel() }
            var applied: [ListSection<String>]?
            var lastRows: [TrackerItem] = []
            for step in 0..<250 {
                let what = step == 0 ? "first state" : try writes.step()
                store.itemsIndex.waitUntilIdle()
                await MainActor.run {}
                // Read again while waiting: before the first snapshot has
                // landed the index holds nothing.
                var state = store.itemsIndex.currentState
                var want = state.forYouSections()
                let context = "seed \(seed) step \(step) (\(what))"
                var failure: String?
                try await waitUntil {
                    for publication in log.drain() {
                        let update = publication.update
                        if applied == nil, !update.isReset { failure = "\(context): the first update is not a reset" }
                        guard let next = update.apply(to: applied ?? []) else {
                            failure = "\(context): \(update) does not fit \(applied ?? [])"
                            continue
                        }
                        if publication.rows.map(\.id) != next.flatMap(\.ids) {
                            failure = "\(context): the rows are not in the update's order"
                        }
                        if !update.isReset {
                            edits += 1
                            moves += update.moved.count
                            crossSection += update.moved.filter { $0.from.section != $0.to.section }.count
                            inserts += update.inserted.count
                            removes += update.removed.count
                            reconfigures += update.reconfigured.count
                        }
                        applied = next
                        lastRows = publication.rows
                    }
                    state = store.itemsIndex.currentState
                    want = state.forYouSections()
                    return failure != nil || applied == want
                }
                if let failure { return XCTFail(failure) }
                guard applied == want else {
                    return XCTFail("\(context): applied \(applied ?? []) != \(want)")
                }
                XCTAssertEqual(want.map(\.key), ItemsIndexState.forYouSectionKeys, context)
                XCTAssertEqual(lastRows, state.sections.needsYou + state.sections.decided, context)
            }
        }
        XCTAssertGreaterThan(edits, 50, "most commits arrive as edits, not resets")
        XCTAssertGreaterThan(moves, 0)
        XCTAssertGreaterThan(crossSection, 0)
        XCTAssertGreaterThan(inserts, 0)
        XCTAssertGreaterThan(removes, 0)
        XCTAssertGreaterThan(reconfigures, 0)
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
        XCTAssertEqual(fed.touched.last, ItemsIndexState.Touched(lists: [.tasks], origins: ["c1": [.tasks]]))
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
        XCTAssertEqual(fed.touched.last, ItemsIndexState.Touched(lists: [.needsYou, .decided],
                                                                 origins: ["c1": [.needsYou, .decided]],
                                                                 needsUserCounts: true, missions: ["m1"], missionItems: ["m1"],
                                                                 forYouIDs: ["q11"]))
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
        XCTAssertEqual(fed.state.slices.compactMapValues { $0.tasks.isEmpty ? nil : $0.tasks }, try fresh(store).tasksByOrigin)
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
        var sections = store.itemSectionsStream(scope: .all).makeAsyncIterator()
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
            sections.consume(try XCTUnwrap(store).itemSectionsStream(scope: .all)),
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
        var iterator = store.itemSectionsStream(scope: .all).makeAsyncIterator()
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

extension ItemsIndexTests {
    // MARK: Per conversation, mission and project

    /// A write in one conversation re-delivers that conversation's
    /// sections, and not another's: the pane of a chat the user is not
    /// writing in hears nothing.
    func testAWriteInOneConversationDoesNotRepublishAnothersSections() async throws {
        let store = try makeStore()
        try store.upsertItems([item("a1", num: 1, origin: "a"), item("b1", num: 2, origin: "b")])
        let a = OSAllocatedUnfairLock(initialState: [[String]]())
        let b = OSAllocatedUnfairLock(initialState: [[String]]())
        let index = store.itemsIndex
        let tokens = [
            index.observeSections(origin: "a") { value in a.withLock { $0.append(value.tasks.map(\.title)) } },
            index.observeSections(origin: "b") { value in b.withLock { $0.append(value.tasks.map(\.title)) } },
        ]
        defer { tokens.forEach { $0.cancel() } }
        try await waitUntil { a.withLock { $0.count } == 1 && b.withLock { $0.count } == 1 }

        try store.upsertItems([item("a1", num: 1, title: "Renamed", origin: "a", updated: 1_900_000_001)])
        try store.upsertItems([item("a2", num: 3, origin: "a", updated: 1_900_000_002)])
        try await waitUntil { a.withLock { $0.count } == 3 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(a.withLock { $0 }.last, ["Renamed", "Item 3"])
        XCTAssertEqual(b.withLock { $0 }, [["Item 2"]], "b's sections were not re-delivered")

        // An item moving from a to b is a change to both.
        try store.upsertItems([item("a2", num: 3, origin: "b", updated: 1_900_000_003)])
        try await waitUntil { a.withLock { $0.count } == 4 && b.withLock { $0.count } == 2 }
        XCTAssertEqual(a.withLock { $0 }.last, ["Renamed"])
        XCTAssertEqual(b.withLock { $0 }.last, ["Item 2", "Item 3"])
    }

    /// Likewise per mission: a write to one mission's item re-delivers that
    /// mission's lists only.
    func testAWriteInOneMissionDoesNotRepublishAnothersLists() async throws {
        let store = try makeStore()
        try store.upsertItems([item("x", num: 1, mission: "m1"), item("y", num: 2, mission: "m2"),
                               item("z", num: 3, state: .closed, awaiting: nil, mission: "m2")])
        let m1 = OSAllocatedUnfairLock(initialState: 0), m2 = OSAllocatedUnfairLock(initialState: 0)
        let m2Closed = OSAllocatedUnfairLock(initialState: 0), m2Count = OSAllocatedUnfairLock(initialState: [Int]())
        let index = store.itemsIndex
        let tokens = [
            index.observeOpenItems(missionID: "m1") { _ in m1.withLock { $0 += 1 } },
            index.observeOpenItems(missionID: "m2") { _ in m2.withLock { $0 += 1 } },
            index.observeClosedItems(missionID: "m2", limit: 10) { _ in m2Closed.withLock { $0 += 1 } },
            index.observeClosedItemsCount(missionID: "m2") { count in m2Count.withLock { $0.append(count) } },
        ]
        defer { tokens.forEach { $0.cancel() } }
        try await waitUntil { m1.withLock { $0 } == 1 && m2.withLock { $0 } == 1 && m2Closed.withLock { $0 } == 1 }

        try store.upsertItems([item("x", num: 1, title: "Renamed", mission: "m1", updated: 1_900_000_001)])
        try await waitUntil { m1.withLock { $0 } == 2 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(m2.withLock { $0 }, 1)
        XCTAssertEqual(m2Closed.withLock { $0 }, 1)

        // Closing m2's open item moves it between m2's two lists.
        try store.upsertItems([item("y", num: 2, state: .closed, awaiting: nil, mission: "m2", updated: 1_900_000_002)])
        try await waitUntil { m2.withLock { $0 } == 2 && m2Closed.withLock { $0 } == 2 && m2Count.withLock { $0 } == [1, 2] }
        XCTAssertEqual(m1.withLock { $0 }, 2)
    }

    /// A project's item streams follow its missions: an item on a mission
    /// filed into the project appears, and leaves when the mission moves to
    /// another project, with each value equal to the project query's.
    func testProjectItemStreamsFollowTheProjectsMissions() async throws {
        let store = try makeStore()
        try store.upsertMissions([
            Mission(id: "m1", num: 1, title: "M1", originConvoID: "c1", projectID: "p1"),
            Mission(id: "m2", num: 2, title: "M2", originConvoID: "c1", projectID: "p2"),
        ])
        try store.upsertItems([item("q1", num: 1, kind: .question, awaiting: .user, mission: "m1"),
                               item("q2", num: 2, kind: .question, awaiting: .user, mission: "m2", updated: 1_900_000_001),
                               item("t3", num: 3, mission: "m1", updated: 1_900_000_002)])
        let open = Latest<[TrackerItem]>(), needsYou = Latest<[TrackerItem]>()
        let consumers = [open.consume(store.openItemsStream(projectID: "p1")),
                         needsYou.consume(store.needsYouItemsStream(projectID: "p1"))]
        defer { consumers.forEach { $0.cancel() } }
        try await waitUntil { open.value?.map(\.id) == ["t3", "q1"] && needsYou.value?.map(\.id) == ["q1"] }

        try store.upsertMissions([Mission(id: "m2", num: 2, title: "M2", originConvoID: "c1", projectID: "p1")])
        try await waitUntil { open.value?.map(\.id) == ["t3", "q2", "q1"] && needsYou.value?.map(\.id) == ["q2", "q1"] }

        try store.upsertItems([item("q2", num: 2, kind: .question, awaiting: .agent, mission: "m2", updated: 1_900_000_003)])
        try await waitUntil { open.value?.map(\.id) == ["q2", "t3", "q1"] && needsYou.value?.map(\.id) == ["q1"] }

        try store.upsertMissions([Mission(id: "m1", num: 1, title: "M1", originConvoID: "c1", projectID: "p2")])
        try await waitUntil { open.value?.map(\.id) == ["q2"] && needsYou.value == [] }
        XCTAssertEqual(open.value, try projectQuery(store, "p1").open)
        XCTAssertEqual(needsYou.value, try projectQuery(store, "p1").needsYou)
    }

    private func projectQuery(_ store: JournalStore, _ project: String) throws -> (open: [TrackerItem], needsYou: [TrackerItem]) {
        try store.db.read { db in
            (try JournalStore.projectOpenItems(db, project), try JournalStore.projectNeedsYouItems(db, project))
        }
    }

    // MARK: Consistency check

    /// The check the Debug build runs once a minute finds nothing after a
    /// random sequence of real writes: the live index equals one loaded
    /// from a full read at the same point in the commit order.
    func testTheConsistencyCheckFindsNoDifferenceAfterRandomWrites() async throws {
        let store = try makeStore()
        var writes = RandomItemWrites(store: store, seed: 7)
        var iterator = store.itemSectionsStream(scope: .all).makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<300 { try writes.step() }
        let found = OSAllocatedUnfairLock(initialState: [String]?.none)
        store.itemsIndex.checkConsistency { mismatches in found.withLock { $0 = mismatches } }
        try await waitUntil { found.withLock { $0 } != nil }
        XCTAssertEqual(found.withLock { $0 }, [])
    }

    /// `mismatches(against:)` names each projection that differs.
    func testMismatchesNameWhatDiffers() {
        func record(_ item: TrackerItem) -> ItemRecord { ItemRecord(item) }
        let rows: [(Int64, ItemRecord)] = [
            (1, record(item("t", num: 1, mission: "m1"))),
            (2, record(item("q", num: 2, kind: .question, awaiting: .user, origin: "c2", mission: "m1"))),
        ]
        var live = ItemsIndexState(), fresh = ItemsIndexState()
        live.load(rows); fresh.load(rows)
        XCTAssertEqual(live.mismatches(against: fresh), [])

        // A change the live state never heard of.
        fresh.apply(RowChanges(upserted: [2: record(item("q", num: 2, kind: .question, awaiting: .agent, origin: "c2",
                                                         mission: "m1", updated: 1_900_000_001))]))
        let found = live.mismatches(against: fresh)
        XCTAssertTrue(found.contains("sections"), "\(found)")
        XCTAssertTrue(found.contains("sections of conversation c2"), "\(found)")
        XCTAssertTrue(found.contains("needs-you counts"), "\(found)")
        XCTAssertTrue(found.contains("open items of mission m1"), "\(found)")
        XCTAssertFalse(found.contains("sections of conversation c1"), "\(found)")
    }
}

final class ItemsIndexPoolTests: ItemsIndexTests {
    override class var writerKind: StoreWriterKind { .pool }
}

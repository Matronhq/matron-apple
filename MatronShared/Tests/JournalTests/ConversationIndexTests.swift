import GRDB
import os
import XCTest
@testable import MatronJournal

/// `ConversationIndex`: every conversation row, kept current from the change
/// feed, serving the four conversation streams with exactly the values
/// today's whole-table fetches return.
final class ConversationIndexTests: XCTestCase {
    private func makeStore(usesChangeFeed: Bool = true) throws -> JournalStore {
        try JournalStore(databaseURL: nil, ownSender: RandomJournalWrites.ownSender,
                         metrics: StoreMetrics(), usesChangeFeed: usesChangeFeed)
    }

    private func event(_ seq: Int64, convo: String = "c1", ts: Date? = nil, sender: String = "agent:box-2",
                       type: String = JournalEventType.text, payload: [String: Any] = ["body": "hi"]) -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: ts ?? Date(timeIntervalSince1970: Double(seq)),
                     sender: sender, type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    /// An index state fed synchronously by the change feed: events arrive
    /// on the writer inside each commit, so it is current when the write
    /// call returns.
    private final class FedState: @unchecked Sendable {
        private let lock = NSLock()
        private var _state = ConversationIndexState()
        var state: ConversationIndexState { lock.withLock { _state } }
        func handle(_ event: StoreFeedEvent<[(Int64, ConversationRecord)]>) {
            lock.withLock { _ = _state.apply(event) }
        }
    }

    private func feedState(_ store: JournalStore) throws -> (FedState, StoreChangeFeed.Subscription) {
        let fed = FedState()
        let subscription = store.observeChanges(
            snapshot: { db in try StoreChangeFeed.conversationRows(db) },
            onEvent: fed.handle, onError: { XCTFail("feed error: \($0)") })
        _ = try store.dbQueue.read { _ in }
        return (fed, subscription)
    }

    // MARK: The gate

    /// The equivalence property: after every commit of a seeded random
    /// sequence of real store writes, each projection of an index built
    /// from snapshot plus change sets equals what today's observation
    /// fetches return from a fresh read: the chat list (TTL applied at the
    /// same instant), the session-state map, the rooms, and the children
    /// of every conversation.
    func testProjectionsEqualTodaysFetchesAfterEveryCommit() throws {
        let parents = RandomJournalWrites.convoIDs + RandomJournalWrites.quietIDs
        for seed in UInt64(1)...6 {
            let store = try makeStore(usesChangeFeed: false)
            var writes = RandomJournalWrites(store: store, seed: seed)
            for _ in 0..<20 { try writes.step() }
            let (fed, subscription) = try feedState(store)
            defer { subscription.cancel() }
            var sawTies = false, sawNullActivity = false, sawRooms = false, sawChildren = false, sawExpired = false
            for step in 0..<400 {
                let what = try writes.step()
                let now = writes.now
                let state = fed.state
                let context = "seed \(seed) step \(step) (\(what))"
                let expected = try store.dbQueue.read { db in
                    (chatList: try JournalStore.chatList(db, now: now),
                     sessionStates: try JournalStore.sessionStateMap(db),
                     rooms: try JournalStore.missionRoomRows(db),
                     children: try parents.map { try JournalStore.childRecords(db, of: $0) })
                }
                let chatList = state.chatList(now: now).records
                guard chatList == expected.chatList else {
                    return XCTFail("\(context): chat list \(chatList.map(\.id)) != \(expected.chatList.map(\.id))")
                }
                guard state.sessionStates == expected.sessionStates else {
                    return XCTFail("\(context): session states diverged")
                }
                guard state.rooms() == expected.rooms else {
                    return XCTFail("\(context): rooms \(state.rooms().map(\.id)) != \(expected.rooms.map(\.id))")
                }
                for (parent, children) in zip(parents, expected.children) where state.children(of: parent) != children {
                    return XCTFail("\(context): children of \(parent) diverged")
                }
                sawTies = sawTies || zip(chatList, chatList.dropFirst()).contains {
                    $0.lastActivityTS == $1.lastActivityTS && $0.lastSeq == $1.lastSeq
                }
                sawNullActivity = sawNullActivity || chatList.contains { $0.lastActivityTS == nil }
                sawRooms = sawRooms || expected.rooms.count > 1
                sawChildren = sawChildren || expected.children.contains { $0.count > 1 }
                sawExpired = sawExpired || chatList.contains { $0.expiredSnippet != nil && $0.snippet == $0.expiredSnippet }
            }
            // The sequence must reach the cases the order and filters turn on.
            XCTAssertTrue(sawTies, "seed \(seed): ties on activity and seq")
            XCTAssertTrue(sawNullActivity, "seed \(seed): rows with no activity time")
            XCTAssertTrue(sawRooms, "seed \(seed): several rooms")
            XCTAssertTrue(sawChildren, "seed \(seed): several children of one parent")
            XCTAssertTrue(sawExpired, "seed \(seed): an expired tool-output snippet")
        }
    }

    // MARK: Order and filters

    /// SQLite sorts NULL lowest: last under `DESC`. Rows equal on activity
    /// and seq come out in rowid order.
    func testChatListOrderMatchesSQLiteForNullActivityAndTies() throws {
        let store = try makeStore(usesChangeFeed: false)
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "null-low", title: "", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 0),
            ConvoSummaryDTO(id: "tie-b", title: "", sessionState: "running", lastSeq: 5, snippet: "", createdAt: 0, lastTS: 2_000),
            ConvoSummaryDTO(id: "null-high", title: "", sessionState: "running", lastSeq: 9, snippet: "", createdAt: 0),
            ConvoSummaryDTO(id: "newest", title: "", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 0, lastTS: 3_000),
            ConvoSummaryDTO(id: "tie-a", title: "", sessionState: "running", lastSeq: 5, snippet: "", createdAt: 0, lastTS: 2_000),
            ConvoSummaryDTO(id: "null-tie", title: "", sessionState: "running", lastSeq: 1, snippet: "", createdAt: 0),
        ], headSeq: 9)
        let expected = ["newest", "tie-b", "tie-a", "null-high", "null-low", "null-tie"]
        XCTAssertEqual(try store.conversations().map(\.id), expected, "precondition: SQLite's own order")
        XCTAssertEqual(fed.state.chatList(now: Date()).records.map(\.id), expected)
    }

    /// Hidden rows and subagent children are out of the chat list exactly
    /// as today, and still in the session-state map and the children
    /// projection. (Pinning is not a conversation column: the chat list
    /// partitions pinned rows after this point, so the index carries them
    /// like any other row.)
    func testHiddenAndChildRowsAreOutOfTheChatListAndInTheProjections() throws {
        let store = try makeStore(usesChangeFeed: false)
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }
        try store.applyJournal(event(1, convo: "parent"))
        try store.applyJournal(event(2, convo: "child", type: JournalEventType.convoMeta,
                                     payload: ["parent_convo_id": "parent", "title": "Child"]))
        try store.applyJournal(event(3, convo: "hidden", type: JournalEventType.sessionStatus, payload: ["state": "done"]))
        try store.setHidden(true, convoID: "hidden")
        try store.applyJournal(event(4, convo: "room", type: JournalEventType.convoMeta,
                                     payload: ["participant_convos": ["parent"]]))

        let state = fed.state
        // The room's only frame is a convo_meta, which is not activity.
        XCTAssertEqual(state.chatList(now: Date()).records.map(\.id), ["parent", "room"])
        XCTAssertEqual(state.sessionStates, ["parent": "running", "child": "running", "hidden": "done", "room": "running"])
        XCTAssertEqual(state.children(of: "parent").map(\.id), ["child"])
        XCTAssertEqual(state.rooms().map(\.id), ["room"])
        let expected = try store.dbQueue.read { db in
            (try JournalStore.sessionStateMap(db), try JournalStore.childRecords(db, of: "parent"))
        }
        XCTAssertEqual(state.sessionStates, expected.0)
        XCTAssertEqual(state.children(of: "parent"), expected.1)
    }

    /// Delete-then-insert in one transaction can hand a rowid to a new key,
    /// or move a key to a new rowid. Either way the index ends up holding
    /// exactly the table's rows. (No store API deletes one conversation
    /// today, so this goes through SQL.)
    func testRowidReuseAndAMovedKeyLeaveExactlyTheTablesRows() throws {
        let store = try makeStore(usesChangeFeed: false)
        try store.ensureConversation(id: "a", title: "A")
        try store.ensureConversation(id: "b", title: "B")
        let (fed, subscription) = try feedState(store)
        defer { subscription.cancel() }

        try store.dbQueue.write { db in
            // "b" holds the highest rowid, so "c" reuses it; "a" comes
            // back on a new rowid.
            try db.execute(sql: "DELETE FROM conversation WHERE id IN ('a', 'b')")
            try db.execute(sql: "INSERT INTO conversation(id, title, session_state) VALUES('c', 'C', 'done')")
            try db.execute(sql: "INSERT INTO conversation(id, title, session_state) VALUES('a', 'A again', 'waiting')")
        }

        let state = fed.state
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.sessionStates, ["a": "waiting", "c": "done"])
        XCTAssertEqual(state.chatList(now: Date()).records, try store.conversations())
    }

    // MARK: Streams in index mode

    func testIndexModeStreamsDeliverOnTheMainQueue() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        let offMain = OSAllocatedUnfairLock(initialState: 0)
        let values = OSAllocatedUnfairLock(initialState: [[String]]())
        let token = store.conversationIndex.observeChatList { records in
            if !Thread.isMainThread { offMain.withLock { $0 += 1 } }
            values.withLock { $0.append(records.map(\.id)) }
        }
        defer { token.cancel() }
        try await waitUntil { values.withLock { $0.count } == 1 }
        try store.applyJournal(event(2, convo: "c2"))
        try await waitUntil { values.withLock { $0.count } == 2 }
        XCTAssertEqual(values.withLock { $0 }, [["c1"], ["c2", "c1"]])
        XCTAssertEqual(offMain.withLock { $0 }, 0, "every delivery lands on the main queue")
    }

    /// One shared index per store, started by the first subscriber: one
    /// feed subscription however many streams are open.
    func testOneIndexPerStoreStartedByTheFirstSubscriber() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1))
        XCTAssertEqual(store.changeFeed.subscriberCount, 0, "nothing runs before a stream is opened")

        var list = store.conversationsStream().makeAsyncIterator()
        var states = store.sessionStatesStream().makeAsyncIterator()
        var rooms = store.missionRoomsStream().makeAsyncIterator()
        var children = store.childrenStream(of: "c1").makeAsyncIterator()
        let firstList = await list.next()
        let firstStates = await states.next()
        let firstRooms = await rooms.next()
        let firstChildren = await children.next()
        XCTAssertEqual(firstList?.map(\.id), ["c1"])
        XCTAssertEqual(firstStates, ["c1": "running"])
        XCTAssertEqual(firstRooms, [])
        XCTAssertEqual(firstChildren, [])
        XCTAssertEqual(store.changeFeed.subscriberCount, 1)
    }

    /// The flag off leaves the store exactly as before: no index, no feed
    /// subscriber, the value observations.
    func testFlagOffServesTheValueObservations() async throws {
        let store = try makeStore(usesChangeFeed: false)
        try store.applyJournal(event(1))
        var list = store.conversationsStream().makeAsyncIterator()
        let first = await list.next()
        XCTAssertEqual(first?.map(\.id), ["c1"])
        XCTAssertEqual(store.changeFeed.subscriberCount, 0)
        XCTAssertNil(store.startedConversationIndex)
    }

    /// `removeDuplicates` semantics: a commit that leaves the chat list as
    /// it was (traffic in a hidden conversation) is not delivered.
    func testIndexModeDoesNotDeliverAnUnchangedChatList() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "c-visible"))
        try store.applyJournal(event(2, convo: "c-hidden"))
        try store.setHidden(true, convoID: "c-hidden")

        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.id), ["c-visible"])

        try store.applyJournal(event(3, convo: "c-hidden"))
        try await Task.sleep(for: .milliseconds(150))
        try store.applyJournal(event(4, convo: "c-visible", payload: ["body": "bumped"]))
        let updated = await iterator.next()
        XCTAssertEqual(updated?.first?.lastSeq, 4,
                       "hidden-convo traffic must be deduplicated, not delivered as a stale list")
    }

    /// Each projection delivers only when its own value changes: a snippet
    /// changes the chat list, not the session-state map or the rooms.
    func testIndexModeProjectionsDeliverOnlyTheirOwnChanges() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "room", type: JournalEventType.convoMeta,
                                     payload: ["participant_convos": ["a"]]))
        let states = OSAllocatedUnfairLock(initialState: [[String: String]]())
        let rooms = OSAllocatedUnfairLock(initialState: [[JournalStore.RoomRow]]())
        let index = store.conversationIndex
        let t1 = index.observeSessionStates { value in states.withLock { $0.append(value) } }
        let t2 = index.observeRooms { value in rooms.withLock { $0.append(value) } }
        defer { t1.cancel(); t2.cancel() }
        try await waitUntil { states.withLock { $0.count } == 1 && rooms.withLock { $0.count } == 1 }

        try store.applyJournal(event(2, convo: "room", payload: ["body": "snippet only"]))
        try store.applyJournal(event(3, convo: "room", type: JournalEventType.sessionStatus, payload: ["state": "done"]))
        try await waitUntil { states.withLock { $0.count } == 2 && rooms.withLock { $0.count } == 3 }
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(states.withLock { $0 }.map { $0["room"] }, ["running", "done"])
        // The room row carries the activity time (the text bumped it) and
        // the state, but not the snippet.
        XCTAssertEqual(rooms.withLock { $0 }.count, 3)
        XCTAssertEqual(rooms.withLock { $0 }.last?.first?.sessionState, "done")
    }

    /// One journal frame changes only its own row in the emitted list.
    func testOneFrameChangesOnlyItsRow() async throws {
        let store = try makeStore()
        for (seq, convo) in ["a", "b", "c", "d"].enumerated() {
            try store.applyJournal(event(Int64(seq + 1), convo: convo))
        }
        var iterator = store.conversationsStream().makeAsyncIterator()
        let beforeNext = await iterator.next()
        let before = try XCTUnwrap(beforeNext)

        try store.applyJournal(event(5, convo: "b", payload: ["body": "new"]))
        let afterNext = await iterator.next()
        let after = try XCTUnwrap(afterNext)

        XCTAssertEqual(after.map(\.id), ["b", "d", "c", "a"])
        XCTAssertEqual(after.filter { $0.id != "b" }, before.filter { $0.id != "b" },
                       "every other row is the same value")
        XCTAssertEqual(after.first?.snippet, "new")
    }

    func testWipeReloadsTheIndex() async throws {
        let store = try makeStore()
        try store.applyJournal(event(1, convo: "a"))
        var iterator = store.conversationsStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial?.map(\.id), ["a"])

        try store.wipe()
        let wiped = await iterator.next()
        XCTAssertEqual(wiped, [])

        try store.applyJournal(event(2, convo: "b"))
        let refilled = await iterator.next()
        XCTAssertEqual(refilled?.map(\.id), ["b"])
    }

    // MARK: Snippet TTL

    /// A live tool-output snippet older than 24 h is replaced by its
    /// `$ command` form on emission; other snippets are untouched.
    func testExpiredToolOutputSnippetIsHiddenOnEmission() async throws {
        let store = try makeStore()
        let old = Date().addingTimeInterval(-25 * 3600)
        try store.applyJournal(event(1, convo: "tool", ts: old, type: JournalEventType.toolOutput,
                                     payload: ["command": "make", "snippet": "building…", "live_log": true]))
        try store.applyJournal(event(2, convo: "legacy", ts: old, type: JournalEventType.toolOutput,
                                     payload: ["command": "make", "snippet": "durable"]))
        try store.applyJournal(event(3, convo: "text", ts: old, payload: ["body": "hello"]))

        var iterator = store.conversationsStream().makeAsyncIterator()
        let listNext = await iterator.next()
        let list = try XCTUnwrap(listNext)
        let snippets = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.snippet) })
        XCTAssertEqual(snippets, ["tool": "$ make", "legacy": "durable", "text": "hello"])
        XCTAssertEqual(list, try store.conversations(), "the same value the one-shot read returns")
    }

    /// A live snippet that crosses 24 h while the index is running is hidden
    /// by exactly one update, with no write; the other rows are untouched.
    func testSnippetCrossingTheTTLWhileLiveIsHiddenByExactlyOneUpdate() async throws {
        let store = try makeStore()
        let almost = Date().addingTimeInterval(-EventTombstone.toolLogTTL + 0.4)
        try store.applyJournal(event(1, convo: "tool", ts: almost, type: JournalEventType.toolOutput,
                                     payload: ["command": "make", "snippet": "building…", "live_log": true]))
        try store.applyJournal(event(2, convo: "text", ts: almost, payload: ["body": "hello"]))

        let values = OSAllocatedUnfairLock(initialState: [[String: String]]())
        let token = store.conversationIndex.observeChatList { list in
            values.withLock { $0.append(Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.snippet) })) }
        }
        defer { token.cancel() }
        try await waitUntil { values.withLock { $0.count } == 1 }
        XCTAssertEqual(values.withLock { $0 }.first, ["tool": "building…", "text": "hello"])

        try await waitUntil { values.withLock { $0.count } == 2 }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(values.withLock { $0 }, [
            ["tool": "building…", "text": "hello"],
            ["tool": "$ make", "text": "hello"],
        ], "exactly one update, and only the expired row changed")
    }

    /// The timer follows the earliest pending expiry as rows change: a
    /// newer frame in the same conversation takes the row's expiry away.
    func testANewerFrameCancelsThePendingExpiry() async throws {
        let store = try makeStore()
        let almost = Date().addingTimeInterval(-EventTombstone.toolLogTTL + 0.3)
        try store.applyJournal(event(1, convo: "tool", ts: almost, type: JournalEventType.toolOutput,
                                     payload: ["command": "make", "snippet": "building…", "live_log": true]))
        let values = OSAllocatedUnfairLock(initialState: [String]())
        let token = store.conversationIndex.observeChatList { list in
            values.withLock { $0.append(list.first?.snippet ?? "") }
        }
        defer { token.cancel() }
        try await waitUntil { values.withLock { $0.count } == 1 }
        try store.applyJournal(event(2, convo: "tool", ts: Date(), payload: ["body": "fresh"]))
        try await waitUntil { values.withLock { $0.count } == 2 }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(values.withLock { $0 }, ["building…", "fresh"])
    }
}

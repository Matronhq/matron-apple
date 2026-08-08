import XCTest
@testable import MatronJournal
import MatronSearch

/// In-memory `SearchService` mirroring `SearchServiceLive`'s bookkeeping
/// semantics closely enough for coordinator tests: indexed events keyed by
/// event id, per-room backfill progress rows.
private actor InMemorySearchService: SearchService {
    struct Indexed: Equatable { let roomID: String; let eventID: String; let sender: String; let body: String }
    struct Progress { var indexedCount: Int; var oldestEventID: String?; var complete: Bool }

    private(set) var indexed: [String: Indexed] = [:]
    private(set) var progress: [String: Progress] = [:]

    func seedProgress(roomID: String, oldestEventID: String?, complete: Bool) {
        progress[roomID] = Progress(indexedCount: 0, oldestEventID: oldestEventID, complete: complete)
    }

    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        indexed[eventID] = Indexed(roomID: roomID, eventID: eventID, sender: sender, body: body)
    }
    func remove(eventID: String) async throws { indexed[eventID] = nil }
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func wipe() async throws { indexed = [:]; progress = [:] }
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {
        progress[roomID] = Progress(indexedCount: indexedCount, oldestEventID: oldestEventID, complete: complete)
    }
    func backfillComplete(roomID: String) async throws -> Bool { progress[roomID]?.complete ?? false }
    func backfillOldestEventID(roomID: String) async throws -> String? { progress[roomID]?.oldestEventID }
    func resetBackfill() async throws { progress = [:] }
    func eventCount(roomID: String) async throws -> Int { indexed.values.filter { $0.roomID == roomID }.count }
    func contains(eventID: String) async throws -> Bool { indexed[eventID] != nil }
}

/// Scripted page server: serves `events` the way the journal server does —
/// `beforeSeq == nil` returns the newest `limit` events, otherwise the newest
/// `limit` events with `seq < beforeSeq`, ascending. Records every call.
private actor ScriptedPager {
    struct Call: Equatable { let convoID: String; let beforeSeq: Int64? }
    private let events: [JournalEvent]
    private var failOnCall: Int?
    private(set) var calls: [Call] = []

    init(events: [JournalEvent], failOnCall: Int? = nil) {
        self.events = events.sorted { $0.seq < $1.seq }
        self.failOnCall = failOnCall
    }

    func stopFailing() { failOnCall = nil }

    func page(convoID: String, beforeSeq: Int64?, limit: Int) throws -> [JournalEvent] {
        calls.append(Call(convoID: convoID, beforeSeq: beforeSeq))
        if calls.count == failOnCall { throw URLError(.notConnectedToInternet) }
        let eligible = events.filter { $0.convoID == convoID && (beforeSeq == nil || $0.seq < beforeSeq!) }
        return Array(eligible.suffix(limit))
    }
}

private func makeEvent(seq: Int64, convoID: String = "c1", type: String = JournalEventType.text,
                       payload: [String: Any] = ["body": "hello"]) -> JournalEvent {
    JournalEvent(seq: seq, convoID: convoID, ts: Date(timeIntervalSince1970: Double(seq)),
                 sender: "user:dan", type: type,
                 payloadData: try! JSONSerialization.data(withJSONObject: payload))
}

final class SearchBackfillCoordinatorTests: XCTestCase {
    private func makeCoordinator(search: InMemorySearchService, pager: ScriptedPager,
                                 pageSize: Int = 2) -> SearchBackfillCoordinator {
        SearchBackfillCoordinator(
            search: search,
            fetchPage: { convoID, beforeSeq, limit in
                try await pager.page(convoID: convoID, beforeSeq: beforeSeq, limit: limit)
            },
            pageSize: pageSize, throttle: .zero
        )
    }

    func test_fullWalk_indexesAllPagesAndMarksComplete() async throws {
        let search = InMemorySearchService()
        let events = (1...5).map { makeEvent(seq: Int64($0), payload: ["body": "msg \($0)"]) }
        let pager = ScriptedPager(events: events)
        let coordinator = makeCoordinator(search: search, pager: pager)

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "2", "3", "4", "5"]))
        XCTAssertEqual(indexed["3"]?.body, "msg 3")
        let progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
        XCTAssertEqual(progress?.oldestEventID, "1")
        XCTAssertEqual(progress?.indexedCount, 5)
        // Walk order: head page first (nil), then strictly descending.
        let calls = await pager.calls
        XCTAssertEqual(calls.map(\.beforeSeq), [nil, 4, 2])
    }

    func test_completedConversation_isSkippedWithoutFetching() async throws {
        let search = InMemorySearchService()
        await search.seedProgress(roomID: "c1", oldestEventID: "1", complete: true)
        let pager = ScriptedPager(events: [makeEvent(seq: 1)])
        let coordinator = makeCoordinator(search: search, pager: pager)

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let calls = await pager.calls
        XCTAssertTrue(calls.isEmpty)
    }

    // Both of the coordinator's skip paths — the complete flag above and the
    // downward resume below — are blind to a HEAD-side hole. iOS opens the
    // index only once the device unlocks, so events applied during a locked
    // background launch are in the store and not in FTS, right at each
    // conversation's head. Clearing the bookkeeping first (what
    // `startBackfill(resetBookkeepingFirst:)` does, and what
    // `coldStartIfNeeded` already did for the same reason) is what makes the
    // next sweep re-walk from the newest page and pick them up.
    func test_resetBackfill_makesACompletedConversationWalkFromItsHeadAgain() async throws {
        let search = InMemorySearchService()
        await search.seedProgress(roomID: "c1", oldestEventID: "1", complete: true)
        let events = (1...3).map { makeEvent(seq: Int64($0), payload: ["body": "msg \($0)"]) }
        let pager = ScriptedPager(events: events)
        let coordinator = makeCoordinator(search: search, pager: pager, pageSize: 10)

        // Precondition: without the reset, the head-side hole stays a hole.
        _ = await coordinator.run(convoIDs: ["c1"])
        let callsBefore = await pager.calls
        XCTAssertTrue(callsBefore.isEmpty, "a complete room is skipped without fetching")

        try await search.resetBackfill()
        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let calls = await pager.calls
        XCTAssertEqual(calls.map(\.beforeSeq), [nil], "the re-walk must start at the newest page")
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "2", "3"]),
                       "events applied while the index was shut must end up indexed")
    }

    func test_resume_startsFromRecordedOldest() async throws {
        let search = InMemorySearchService()
        await search.seedProgress(roomID: "c1", oldestEventID: "40", complete: false)
        let events = (38...45).map { makeEvent(seq: Int64($0)) }
        let pager = ScriptedPager(events: events)
        let coordinator = makeCoordinator(search: search, pager: pager, pageSize: 10)

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let calls = await pager.calls
        XCTAssertEqual(calls.first?.beforeSeq, 40)
        // Only the events below the resume point were (re-)indexed.
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["38", "39"]))
    }

    func test_nonSearchableEvents_areSkippedButWalkCompletes() async throws {
        let search = InMemorySearchService()
        let events: [JournalEvent] = [
            makeEvent(seq: 1, payload: ["body": "real text"]),
            makeEvent(seq: 2, type: "session_status", payload: ["state": "running"]),
            makeEvent(seq: 3, type: JournalEventType.toolOutput, payload: ["snippet": "tool says"]),
            makeEvent(seq: 4, type: JournalEventType.diff, payload: ["diff": "+ added line"]),
            makeEvent(seq: 5, type: JournalEventType.image, payload: ["blob_ref": "b1"]),
        ]
        let pager = ScriptedPager(events: events)
        let coordinator = makeCoordinator(search: search, pager: pager, pageSize: 10)

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "3", "4"]))
        XCTAssertEqual(indexed["3"]?.body, "tool says")
        XCTAssertEqual(indexed["4"]?.body, "+ added line")
        let progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
    }

    func test_midWalkFailure_leavesResumableProgress_thenRetrySucceeds() async throws {
        let search = InMemorySearchService()
        let events = (1...5).map { makeEvent(seq: Int64($0)) }
        let pager = ScriptedPager(events: events, failOnCall: 2)
        let coordinator = makeCoordinator(search: search, pager: pager)

        let firstPass = await coordinator.run(convoIDs: ["c1"])

        XCTAssertFalse(firstPass)
        var progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, false)
        XCTAssertEqual(progress?.oldestEventID, "4") // page 1 (seqs 4,5) landed
        let indexedAfterFailure = await search.indexed
        XCTAssertEqual(Set(indexedAfterFailure.keys), Set(["4", "5"]))

        await pager.stopFailing()
        let secondPass = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(secondPass)
        progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "2", "3", "4", "5"]))
        // The retry resumed below seq 4 instead of re-walking from the head.
        let calls = await pager.calls
        XCTAssertEqual(calls.map(\.beforeSeq), [nil, 4, 4, 2])
    }

    func test_oneFailingConversation_doesNotBlockTheRest() async throws {
        let search = InMemorySearchService()
        let events = [makeEvent(seq: 1, convoID: "bad"), makeEvent(seq: 2, convoID: "good")]
        let pager = ScriptedPager(events: events, failOnCall: 1) // first call (convo "bad") fails
        let coordinator = makeCoordinator(search: search, pager: pager, pageSize: 10)

        let allComplete = await coordinator.run(convoIDs: ["bad", "good"])

        XCTAssertFalse(allComplete)
        let goodProgress = await search.progress["good"]
        XCTAssertEqual(goodProgress?.complete, true)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["2"]))
    }

    func test_emptyConversation_marksCompleteImmediately() async throws {
        let search = InMemorySearchService()
        let pager = ScriptedPager(events: [])
        let coordinator = makeCoordinator(search: search, pager: pager)

        let allComplete = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(allComplete)
        let progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
        XCTAssertNil(progress?.oldestEventID)
    }

    func test_searchableBody_mapsEventTypesLikeTheTimelineMapper() {
        XCTAssertEqual(makeEvent(seq: 1, payload: ["body": "hi"]).searchableBody, "hi")
        XCTAssertEqual(makeEvent(seq: 2, type: JournalEventType.toolOutput,
                                 payload: ["snippet": "out"]).searchableBody, "out")
        // diff precedence: `diff` wins over `snippet`, snippet is the fallback.
        XCTAssertEqual(makeEvent(seq: 3, type: JournalEventType.diff,
                                 payload: ["diff": "+ d", "snippet": "s"]).searchableBody, "+ d")
        XCTAssertEqual(makeEvent(seq: 4, type: JournalEventType.diff,
                                 payload: ["snippet": "s"]).searchableBody, "s")
        XCTAssertNil(makeEvent(seq: 5, type: JournalEventType.image,
                               payload: ["blob_ref": "b"]).searchableBody)
        XCTAssertNil(makeEvent(seq: 6, payload: ["body": ""]).searchableBody)
    }
}

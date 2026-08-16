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
    /// Size of every `indexBatch` call, in order — the coordinator must
    /// index one BATCH per fetched page (one write transaction), never one
    /// call per event (the 2026-08-10 8.6 GB disk-write exception).
    private(set) var batchSizes: [Int] = []

    /// One-shot hook, awaited after the next `indexBatch` commits — the
    /// interleaving point for the reset-vs-progress race tests (rows landed,
    /// bookkeeping write still ahead). Consumed on first fire so a retry
    /// sweep in the same test runs unhooked.
    private var afterIndexBatch: (@Sendable () async -> Void)?

    func seedProgress(roomID: String, oldestEventID: String?, complete: Bool) {
        progress[roomID] = Progress(indexedCount: 0, oldestEventID: oldestEventID, complete: complete)
    }

    func setAfterNextIndexBatch(_ hook: @escaping @Sendable () async -> Void) {
        afterIndexBatch = hook
    }

    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        indexed[eventID] = Indexed(roomID: roomID, eventID: eventID, sender: sender, body: body)
    }
    func indexBatch(_ entries: [SearchIndexEntry]) async throws {
        batchSizes.append(entries.count)
        for entry in entries {
            try await index(roomID: entry.roomID, eventID: entry.eventID,
                            sender: entry.sender, timestamp: entry.timestamp, body: entry.body)
        }
        if let hook = afterIndexBatch {
            afterIndexBatch = nil
            await hook()
        }
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

/// Late-binding handle so a `fetchPage` closure (or a search-fake hook) can
/// drive the coordinator it is itself a dependency of. Set exactly once,
/// before the sweep starts, then only read — hence `@unchecked Sendable`.
private final class CoordinatorBox: @unchecked Sendable {
    var coordinator: SearchBackfillCoordinator?
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
        // One indexBatch (= one write transaction) per fetched page.
        let batchSizes = await search.batchSizes
        XCTAssertEqual(batchSizes, [2, 2, 1])
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

    // The cold-start race (ported fix — matron-android #41): the engine's
    // snapshot re-bootstrap resets the backfill bookkeeping while a sweep may
    // be mid-batch. Routed through `reset()`, the coordinator's epoch guard
    // must drop the in-flight batch's writes — committing them would
    // resurrect the very bookkeeping the reset cleared (worst case
    // re-marking the room complete, so every later sweep skips the head-side
    // hole the reset exists to expose) — and the next sweep must re-walk
    // from scratch.

    func test_resetInterleavedMidBatch_dropsWritesAndStopsTheSweep() async throws {
        let search = InMemorySearchService()
        let events = (1...3).map { makeEvent(seq: Int64($0), payload: ["body": "msg \($0)"]) }
        let pager = ScriptedPager(events: events)
        let box = CoordinatorBox()
        let coordinator = SearchBackfillCoordinator(
            search: search,
            fetchPage: { convoID, beforeSeq, limit in
                let page = try await pager.page(convoID: convoID, beforeSeq: beforeSeq, limit: limit)
                // Interleave the reset at the batch's widest suspension
                // point: the page is fetched, none of its writes committed.
                if await pager.calls.count == 1 { await box.coordinator?.reset() }
                return page
            },
            pageSize: 10, throttle: .zero
        )
        box.coordinator = coordinator

        let firstPass = await coordinator.run(convoIDs: ["c1", "c2"])

        XCTAssertFalse(firstPass, "an interleaved reset must fail the sweep so the caller retries")
        let indexedAfterReset = await search.indexed
        XCTAssertTrue(indexedAfterReset.isEmpty, "the in-flight batch's rows must be dropped")
        let progressAfterReset = await search.progress
        XCTAssertTrue(progressAfterReset.isEmpty,
                      "no bookkeeping may survive the reset — a resurrected row would make later sweeps skip the room")
        let callsAfterReset = await pager.calls
        XCTAssertEqual(callsAfterReset.map(\.convoID), ["c1"],
                       "the sweep must stop, not roll on to c2 against pre-reset assumptions")

        let secondPass = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(secondPass)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "2", "3"]),
                       "the retry sweep must re-index everything from scratch")
        let progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
        let calls = await pager.calls
        XCTAssertEqual(calls.map(\.beforeSeq), [nil, nil], "the re-walk must start from the newest page")
    }

    func test_resetAfterRowsCommitted_stillDropsTheBookkeepingWrite() async throws {
        let search = InMemorySearchService()
        let events = (1...5).map { makeEvent(seq: Int64($0), payload: ["body": "msg \($0)"]) }
        let pager = ScriptedPager(events: events)
        let box = CoordinatorBox()
        let coordinator = makeCoordinator(search: search, pager: pager)
        box.coordinator = coordinator
        // One suspension later than the test above: page 1's rows have
        // committed, its `recordBackfillProgress` has not.
        await search.setAfterNextIndexBatch { await box.coordinator?.reset() }

        let firstPass = await coordinator.run(convoIDs: ["c1"])

        XCTAssertFalse(firstPass)
        // The rows may stay (`resetBackfill` deliberately preserves indexed
        // messages, and re-indexing is idempotent) — the progress row is the
        // dangerous write, and it must be dropped.
        let progressAfterReset = await search.progress
        XCTAssertTrue(progressAfterReset.isEmpty,
                      "the batch's progress write carries the pre-reset watermark and must not land")

        let secondPass = await coordinator.run(convoIDs: ["c1"])

        XCTAssertTrue(secondPass)
        let indexed = await search.indexed
        XCTAssertEqual(Set(indexed.keys), Set(["1", "2", "3", "4", "5"]))
        let progress = await search.progress["c1"]
        XCTAssertEqual(progress?.complete, true)
        XCTAssertEqual(progress?.oldestEventID, "1")
        // The retry ignored page 1's dropped watermark: head page first,
        // then strictly descending.
        let calls = await pager.calls
        XCTAssertEqual(calls.map(\.beforeSeq), [nil, nil, 4, 2])
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

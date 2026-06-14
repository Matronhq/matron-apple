import XCTest
import GRDB
@testable import MatronSearch

/// Minimal fake pager: returns pre-canned batches in order, then `hitStartOfTimeline = true`.
actor FakePager: TimelinePager {
    var batches: [[BackfillItem]]
    var hitStartAfterLast: Bool

    init(batches: [[BackfillItem]], hitStartAfterLast: Bool = true) {
        self.batches = batches
        self.hitStartAfterLast = hitStartAfterLast
    }

    func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool) {
        if batches.isEmpty { return ([], hitStartAfterLast) }
        let next = batches.removeFirst()
        return (next, batches.isEmpty && hitStartAfterLast)
    }
}

/// Pager that throws for a given room until a target attempt, succeeding
/// thereafter (empty history). Models a room that's on the chat list but not yet
/// in the SDK store on a cold start (`roomNotFound`), then becomes available.
actor FlakyPager: TimelinePager {
    private var remainingFailures: [String: Int]   // roomID → failures left

    init(remainingFailures: [String: Int]) { self.remainingFailures = remainingFailures }

    func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool) {
        if let left = remainingFailures[roomID], left > 0 {
            remainingFailures[roomID] = left - 1
            throw TimelinePagerError.roomNotFound(roomID)
        }
        return ([], true)
    }
}

private enum TimelinePagerError: Error { case roomNotFound(String) }

final class BackfillTests: XCTestCase {
    var url: URL!
    var svc: SearchServiceLive!

    override func setUp() async throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-\(UUID().uuidString).sqlite")
        svc = try SearchServiceLive(databaseURL: url)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: url)
    }

    // Note: async expressions are bound to `let`s before asserting — XCTAssert*
    // take non-async autoclosures, so `try await` cannot live inside them.

    func test_recordsProgressAndCompletion() async throws {
        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 20, oldestEventID: "$o", complete: false)
        let incomplete = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertFalse(incomplete)

        try await svc.recordBackfillProgress(roomID: "!r:s", indexedCount: 50, oldestEventID: "$o2", complete: true)
        let complete = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertTrue(complete)
    }

    func test_backfill_indexesAllIndexableEventsAcrossBatches_andTracksOldest() async throws {
        // Three batches, walking backward in time. Mix in one non-indexable item per batch
        // (image/state/etc) — the runner must skip those.
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$3", sender: "@a:s", timestamp: now.addingTimeInterval(-30), body: "third newest", indexable: true),
                BackfillItem(eventID: "$skipA", sender: "@a:s", timestamp: now.addingTimeInterval(-31), body: "", indexable: false),
            ],
            [
                BackfillItem(eventID: "$2", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "older mid", indexable: true),
            ],
            [
                BackfillItem(eventID: "$1", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "oldest event", indexable: true),
                BackfillItem(eventID: "$skipB", sender: "@a:s", timestamp: now.addingTimeInterval(-91), body: "", indexable: false),
            ],
        ]
        let pager = FakePager(batches: batches)
        let runner = BackfillRunner(timeline: pager, search: svc)

        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: .distantPast)

        // All three indexable events present.
        let count = try await svc.eventCount(roomID: "!r:s")
        XCTAssertEqual(count, 3)
        let oldestHits = try await svc.query("oldest", limit: 10)
        XCTAssertEqual(oldestHits.count, 1)
        let midHits = try await svc.query("mid", limit: 10)
        XCTAssertEqual(midHits.count, 1)

        // Oldest tracked correctly + completion flag set.
        let complete = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertTrue(complete)
        // (We can't introspect oldestEventID directly via the protocol; verify via SQL.)
        let queue = try DatabaseQueue(path: url.path)
        try await queue.read { db in
            let oldest = try String.fetchOne(db, sql: "SELECT backfill_oldest_event_id FROM indexed_rooms WHERE room_id = ?", arguments: ["!r:s"])
            XCTAssertEqual(oldest, "$1")
        }
    }

    func test_backfill_skipsAlreadyIndexedEvents() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        // Pre-index $1 with body "previous-body".
        try await svc.index(roomID: "!r:s", eventID: "$1", sender: "@a:s",
                            timestamp: now.addingTimeInterval(-90), body: "previous-body")
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$1", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "stale-overwrite", indexable: true),
                BackfillItem(eventID: "$2", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "fresh", indexable: true),
            ],
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: .distantPast)

        // $1 must not be re-indexed (still has "previous-body"), $2 added.
        let prev = try await svc.query("previous-body", limit: 10)
        XCTAssertEqual(prev.count, 1)
        let stale = try await svc.query("stale-overwrite", limit: 10)
        XCTAssertEqual(stale.count, 0)
        let fresh = try await svc.query("fresh", limit: 10)
        XCTAssertEqual(fresh.count, 1)
    }

    func test_backfill_honoursDepthLimit() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        // Five indexable events in one batch, but depth limit = 3.
        let batches: [[BackfillItem]] = [
            (1...5).map {
                BackfillItem(eventID: "$\($0)", sender: "@a:s", timestamp: now.addingTimeInterval(Double(-$0) * 10), body: "msg-\($0)", indexable: true)
            }
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches, hitStartAfterLast: false), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 3, sinceCutoff: .distantPast)

        let count = try await svc.eventCount(roomID: "!r:s")
        XCTAssertEqual(count, 3)
    }

    func test_backfill_stopsAtSinceCutoff() async throws {
        let now = Date(timeIntervalSince1970: 1_745_000_000)
        let cutoff = now.addingTimeInterval(-45) // accept events newer than this
        // Two events newer than cutoff, two older. Older must NOT be indexed.
        let batches: [[BackfillItem]] = [
            [
                BackfillItem(eventID: "$new1", sender: "@a:s", timestamp: now.addingTimeInterval(-10), body: "new1", indexable: true),
                BackfillItem(eventID: "$new2", sender: "@a:s", timestamp: now.addingTimeInterval(-30), body: "new2", indexable: true),
                BackfillItem(eventID: "$old1", sender: "@a:s", timestamp: now.addingTimeInterval(-60), body: "old1", indexable: true),
                BackfillItem(eventID: "$old2", sender: "@a:s", timestamp: now.addingTimeInterval(-90), body: "old2", indexable: true),
            ]
        ]
        let runner = BackfillRunner(timeline: FakePager(batches: batches, hitStartAfterLast: false), search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: cutoff)

        let new1 = try await svc.query("new1", limit: 10)
        XCTAssertEqual(new1.count, 1)
        let new2 = try await svc.query("new2", limit: 10)
        XCTAssertEqual(new2.count, 1)
        let old1 = try await svc.query("old1", limit: 10)
        XCTAssertEqual(old1.count, 0)
        let old2 = try await svc.query("old2", limit: 10)
        XCTAssertEqual(old2.count, 0)
    }

    func test_backfill_emptyBatchWithoutStartOfTimeline_doesNotMarkComplete() async throws {
        // bugbot "Empty page marks backfill done": a single empty batch that
        // is NOT the authoritative start-of-timeline signal (the live pager's
        // listener diff hasn't landed yet) must leave the room incomplete, so
        // a later open / next launch retries. Marking it complete would
        // persist a "done" flag and permanently skip the room's history.
        let pager = FakePager(batches: [[]], hitStartAfterLast: false)
        let runner = BackfillRunner(timeline: pager, search: svc)
        try await runner.backfill(roomID: "!r:s", depthLimit: 1000, sinceCutoff: .distantPast)

        let complete = try await svc.backfillComplete(roomID: "!r:s")
        XCTAssertFalse(complete, "an empty, non-terminal batch must leave the room retryable")
    }

    func test_coordinator_emptyRoomList_doesNotLatch_soLaterSweepRuns() async throws {
        // bugbot "Backfill never retries empty snapshot": an empty room list
        // (first non-empty chat-list snapshot hadn't landed) must NOT latch
        // the coordinator — a later call with a populated list must still
        // sweep instead of being skipped for the rest of the session.
        let runner = BackfillRunner(timeline: FakePager(batches: []), search: svc)
        let coordinator = BackfillCoordinator(runner: runner, cutoff: .distantPast)

        await coordinator.run(roomIDs: [])
        let afterEmpty = await coordinator.progress
        XCTAssertEqual(afterEmpty, AggregateBackfillProgress(roomsCompleted: 0, roomsTotal: 0))

        await coordinator.run(roomIDs: ["!a:s", "!b:s"])
        let afterReal = await coordinator.progress
        XCTAssertEqual(
            afterReal, AggregateBackfillProgress(roomsCompleted: 2, roomsTotal: 2),
            "the empty run must not have latched hasRun"
        )
    }

    func test_coordinator_permanentlyFailingRoom_notCountedAsCompleted() async throws {
        // bugbot "Failed room backfill still counts": a room whose backfill
        // keeps throwing must NOT advance `roomsCompleted` — it was never
        // indexed, so counting it done both misreports progress and (with
        // `backfillComplete == false`) it stays retryable next launch.
        let runner = BackfillRunner(timeline: FlakyPager(remainingFailures: ["!b:s": 99]), search: svc)
        let coordinator = BackfillCoordinator(runner: runner, cutoff: .distantPast, retryDelay: .zero)

        await coordinator.run(roomIDs: ["!a:s", "!b:s", "!c:s"])

        let final = await coordinator.progress
        XCTAssertEqual(final.roomsCompleted, 2, "only the two healthy rooms count as done")
        XCTAssertEqual(final.roomsTotal, 3)
        XCTAssertTrue(final.inProgress, "the failed room keeps the sweep visibly incomplete")
    }

    func test_coordinator_transientlyFailingRoom_retriedAndCounted() async throws {
        // A room that fails once (cold-start `roomNotFound`) then succeeds must
        // be retried within the sweep and counted, reaching a full 3/3.
        let runner = BackfillRunner(timeline: FlakyPager(remainingFailures: ["!b:s": 1]), search: svc)
        let coordinator = BackfillCoordinator(runner: runner, cutoff: .distantPast, retryDelay: .zero)

        await coordinator.run(roomIDs: ["!a:s", "!b:s", "!c:s"])

        let final = await coordinator.progress
        XCTAssertEqual(final, AggregateBackfillProgress(roomsCompleted: 3, roomsTotal: 3))
    }

    func test_coordinator_runsAllRoomsAndPublishesProgress() async throws {
        // Empty batches → every room's backfill completes immediately.
        let runner = BackfillRunner(timeline: FakePager(batches: []), search: svc)
        let coordinator = BackfillCoordinator(runner: runner, cutoff: .distantPast)

        await coordinator.run(roomIDs: ["!a:s", "!b:s", "!c:s"])

        let final = await coordinator.progress
        XCTAssertEqual(final, AggregateBackfillProgress(roomsCompleted: 3, roomsTotal: 3))
        XCTAssertFalse(final.inProgress)

        // Idempotent: a second run must not restart the sweep (would reset to 0/1).
        await coordinator.run(roomIDs: ["!x:s"])
        let afterSecond = await coordinator.progress
        XCTAssertEqual(afterSecond.roomsTotal, 3)
    }
}

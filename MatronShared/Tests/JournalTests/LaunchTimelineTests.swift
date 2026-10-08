import XCTest
import MatronModels

/// Ordering, durations and persistence. Deliberately no signpost
/// assertions: `OSSignposter` has no read-back API, and the durations these
/// tests pin are the same numbers the signposts carry.
final class LaunchTimelineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// A timeline whose clock is a script: each read returns the next value,
    /// and the last value repeats.
    private func makeTimeline(_ offsets: [TimeInterval]) -> (LaunchTimeline, UserDefaults) {
        let defaults = UserDefaults(suiteName: "launch-timeline-\(UUID().uuidString)")!
        let box = Box(offsets.map { start.addingTimeInterval($0) })
        return (LaunchTimeline(defaults: defaults, processStart: start, clock: { box.next() }), defaults)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Date]
        init(_ values: [Date]) { self.values = values }
        func next() -> Date {
            lock.lock(); defer { lock.unlock() }
            return values.count > 1 ? values.removeFirst() : values[0]
        }
    }

    func testDurationsAreStoreOpenElapsedAndTheRestLaunchRelative() {
        let (timeline, _) = makeTimeline([0.2, 2.1, 2.4, 6.1])
        timeline.beginStoreOpen()          // t = 0.2
        timeline.endStoreOpen()            // t = 2.1 → storeOpen 1.9
        timeline.mark(.firstListPaint)     // t = 2.4 → 2.4 since process start
        timeline.mark(.catchUpComplete)    // t = 6.1
        let record = timeline.record
        XCTAssertEqual(try XCTUnwrap(record.storeOpen), 1.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.firstListPaint), 2.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.catchUpComplete), 6.1, accuracy: 0.001)
        XCTAssertNil(record.migration, "no migration ran")
    }

    /// The store measures its own migration and hands back a `Duration`
    /// (R7 — nothing in `MatronShared` touches the timeline); the app target
    /// records it inside the `storeOpen` pair.
    func testMigrationIsRecordedInsideStoreOpen() {
        let (timeline, _) = makeTimeline([0.0, 3.5])
        timeline.beginStoreOpen()                      // 0.0
        timeline.endStoreOpen()                        // 3.5 → storeOpen 3.5
        timeline.recordMigration(.milliseconds(3200))
        let record = timeline.record
        XCTAssertEqual(try XCTUnwrap(record.migration), 3.2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.storeOpen), 3.5, accuracy: 0.001)
    }

    func testTheFirstMarkWins() {
        let (timeline, _) = makeTimeline([2.0, 9.0])
        timeline.mark(.firstListPaint)
        timeline.mark(.firstListPaint)
        XCTAssertEqual(try XCTUnwrap(timeline.record.firstListPaint), 2.0, accuracy: 0.001,
                       "a re-appearing list must not overwrite the launch number")
    }

    func testAnUnmatchedEndIsIgnored() {
        let (timeline, _) = makeTimeline([1.0])
        timeline.endStoreOpen()
        XCTAssertNil(timeline.record.storeOpen)
        XCTAssertNil(timeline.record.migration, "no migration is recorded unless one ran")
    }

    func testTheRecordRoundTripsThroughUserDefaults() throws {
        let (timeline, defaults) = makeTimeline([0.0, 1.9, 2.4, 6.1])
        timeline.beginStoreOpen()
        timeline.endStoreOpen()
        timeline.mark(.firstListPaint)
        timeline.mark(.catchUpComplete)

        // `currentLaunch`, not `lastLaunch` (R13): the record is persisted on
        // every mark, so what is on disk describes the launch in progress.
        let restored = try XCTUnwrap(LaunchTimeline.currentLaunch(defaults: defaults))
        XCTAssertEqual(try XCTUnwrap(restored.storeOpen), 1.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(restored.catchUpComplete), 6.1, accuracy: 0.001)
        XCTAssertNotNil(defaults.data(forKey: "launch.last"), "the key the Settings row reads")
    }

    func testSummaryReadsLikeTheSpecExample() {
        let record = LaunchRecord(storeOpen: 1.9, migration: nil, firstListPaint: 2.4,
                                  catchUpComplete: 6.1, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(record),
                       "store 1.9 s · first list 2.4 s · catch-up 6.1 s")
    }

    func testSummaryAppendsMigrationWhenOneRan() {
        let record = LaunchRecord(storeOpen: 4.0, migration: 3.2, firstListPaint: 4.4,
                                  catchUpComplete: 8.0, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(record),
                       "store 4.0 s · first list 4.4 s · catch-up 8.0 s · migration 3.2 s")
    }

    func testSummaryOmitsMarksThatNeverLandedAndHandlesNoRecord() {
        let partial = LaunchRecord(storeOpen: 0.4, migration: nil, firstListPaint: nil,
                                   catchUpComplete: nil, recordedAt: start)
        XCTAssertEqual(LaunchTimeline.summary(partial), "store 0.4 s")
        XCTAssertEqual(LaunchTimeline.summary(nil), "—")
    }

    // MARK: - Fix round 2 (Bugbot: persist race + first-wins)

    /// Bugbot Medium: `mark`/`endStoreOpen`/`recordMigration` used to copy
    /// `_record` under the lock and persist the snapshot AFTER releasing
    /// it, so two concurrent marks (main-actor `firstListPaint` racing the
    /// sync engine's `catchUpComplete`) could persist an earlier snapshot
    /// last and drop a field that had already landed in memory. Persisting
    /// while still holding the lock makes the write atomic with the
    /// mutation, so this must hold for every interleaving: on a real
    /// (non-scripted) clock, hammered many times to shake out any
    /// scheduling-dependent ordering.
    func testConcurrentMarksNeverDropAFieldFromThePersistedRecord() throws {
        for iteration in 0..<200 {
            let defaults = UserDefaults(suiteName: "launch-timeline-concurrent-\(UUID().uuidString)")!
            let timeline = LaunchTimeline(defaults: defaults)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { timeline.mark(.firstListPaint); group.leave() }
            group.enter()
            DispatchQueue.global().async { timeline.mark(.catchUpComplete); group.leave() }
            group.wait()

            let inMemory = timeline.record
            let persisted = try XCTUnwrap(LaunchTimeline.currentLaunch(defaults: defaults),
                                          "iteration \(iteration): nothing was persisted at all")
            XCTAssertNotNil(persisted.firstListPaint, "iteration \(iteration): firstListPaint dropped by a losing persist")
            XCTAssertNotNil(persisted.catchUpComplete, "iteration \(iteration): catchUpComplete dropped by a losing persist")
            XCTAssertEqual(persisted, inMemory,
                           "iteration \(iteration): the persisted record must equal the in-memory one after any interleaving")
        }
    }

    /// Bugbot Low: unlike `mark(_:)`, `endStoreOpen`/`recordMigration` used
    /// to always overwrite, so a second `core(for:)` call in one process
    /// (sign-out → sign-in) would replace this launch's `storeOpen` while
    /// `firstListPaint`/`catchUpComplete` stayed from the first session —
    /// a mixed record. The launch record now describes the first store
    /// open of the process; a second full begin/end cycle is ignored.
    func testASecondStoreOpenCycleDoesNotOverwriteTheFirst() throws {
        let (timeline, _) = makeTimeline([0.0, 2.0, 5.0, 9.0])
        timeline.beginStoreOpen()          // t = 0.0
        timeline.endStoreOpen()            // t = 2.0 → storeOpen 2.0
        timeline.beginStoreOpen()          // must no-op: storeOpen already recorded
        timeline.endStoreOpen()            // must no-op: storeOpenBegan never set
        XCTAssertEqual(try XCTUnwrap(timeline.record.storeOpen), 2.0, accuracy: 0.001,
                       "a second store-open cycle must not replace the first launch's timing")
    }

    /// Same rule for the migration duration the store reports back.
    func testRecordMigrationFirstWins() throws {
        let (timeline, _) = makeTimeline([0.0])
        timeline.recordMigration(.milliseconds(1000))
        timeline.recordMigration(.milliseconds(5000))
        XCTAssertEqual(try XCTUnwrap(timeline.record.migration), 1.0, accuracy: 0.001,
                       "a second migration report must not overwrite the first launch's duration")
    }
}

import XCTest
import GRDB
@testable import MatronJournal

final class StoreMetricsTests: XCTestCase {
    func testFetchesAggregatePerNameAndKeepTheLatestRowCount() {
        let metrics = StoreMetrics()
        metrics.recordFetch("itemsStream.all", duration: .milliseconds(40), rows: 5_000)
        metrics.recordFetch("itemsStream.all", duration: .milliseconds(60), rows: 5_088)
        metrics.recordFetch("itemStream", duration: .milliseconds(1), rows: nil)
        let report = metrics.drain()
        XCTAssertEqual(report.observations, [
            .init(name: "itemsStream.all", fires: 2, totalMS: 100, maxMS: 60, rows: 5_088),
            .init(name: "itemStream", fires: 1, totalMS: 1, maxMS: 1, rows: nil),
        ])
    }

    func testDrainResetsTheWindow() {
        let metrics = StoreMetrics()
        metrics.recordFetch("a", duration: .milliseconds(1), rows: 1)
        metrics.recordWrite("w", duration: .milliseconds(1))
        _ = metrics.drain()
        XCTAssertTrue(metrics.drain().isEmpty)
    }

    /// Nearest-rank p95: for 1…20 ms the 19th value.
    func testWritesReportCountTotalP95AndMax() {
        let metrics = StoreMetrics()
        for ms in 1...20 { metrics.recordWrite("applyJournal", duration: .milliseconds(ms)) }
        metrics.recordWrite("upsertItems", duration: .milliseconds(5))
        let report = metrics.drain()
        XCTAssertEqual(report.writes, [
            .init(name: "applyJournal", commits: 20, totalMS: 210, p95MS: 19, maxMS: 20),
            .init(name: "upsertItems", commits: 1, totalMS: 5, p95MS: 5, maxMS: 5),
        ])
        XCTAssertEqual(report.allWrites, .init(name: "all", commits: 21, totalMS: 215, p95MS: 19, maxMS: 20))
    }

    func testWriteSamplesAreCappedButCountsAreExact() {
        let metrics = StoreMetrics(maxWriteSamplesPerName: 100)
        for _ in 0..<5_000 { metrics.recordWrite("applyJournalBatch", duration: .milliseconds(2)) }
        let stats = metrics.drain().writes[0]
        XCTAssertEqual(stats.commits, 5_000)
        XCTAssertEqual(stats.totalMS, 10_000)
        XCTAssertEqual(stats.p95MS, 2)
    }

    func testConcurrentRecordsAreAllCounted() {
        let metrics = StoreMetrics()
        DispatchQueue.concurrentPerform(iterations: 2_000) { i in
            if i.isMultiple(of: 2) { metrics.recordFetch("f", duration: .microseconds(10), rows: i) }
            else { metrics.recordWrite("w", duration: .microseconds(10)) }
        }
        let report = metrics.drain()
        XCTAssertEqual(report.observations.first?.fires, 1_000)
        XCTAssertEqual(report.writes.first?.commits, 1_000)
    }

    func testLogLinesNameEachActiveObservationAndWrite() {
        let metrics = StoreMetrics()
        metrics.recordFetch("conversationsStream", duration: .milliseconds(12.5), rows: 1_909)
        metrics.recordWrite("applyJournal", duration: .milliseconds(3))
        XCTAssertEqual(metrics.drain().logLines(), [
            "observe conversationsStream fires=1 total_ms=12.5 max_ms=12.5 rows=1909",
            "write applyJournal commits=1 total_ms=3.0 p95_ms=3.0 max_ms=3.0",
            "write all commits=1 total_ms=3.0 p95_ms=3.0 max_ms=3.0",
        ])
    }

    private struct Boom: Error {}

    func testMeasureFetchCountsRowsOfACollectionAndNoneOfAScalar() {
        let metrics = StoreMetrics()
        XCTAssertEqual(metrics.measureFetch("list") { [1, 2, 3] }, [1, 2, 3])
        XCTAssertEqual(metrics.measureFetch("map") { ["a": 1] }, ["a": 1])
        XCTAssertEqual(metrics.measureFetch("one") { Optional(7) }, 7)
        let rows = Dictionary(uniqueKeysWithValues: metrics.drain().observations.map { ($0.name, $0.rows) })
        XCTAssertEqual(rows["list"], .some(3))
        XCTAssertEqual(rows["map"], .some(1))
        XCTAssertEqual(rows["one"], .some(nil))
    }

    /// A throwing fetch must reach GRDB unchanged (the stream restarts on
    /// it) and still be counted: under memory pressure these are exactly
    /// the fetches worth seeing.
    func testMeasureFetchCountsAndRethrowsAThrowingFetch() {
        let metrics = StoreMetrics()
        XCTAssertThrowsError(try metrics.measureFetch("bad") { () throws -> [Int] in throw Boom() }) {
            XCTAssertTrue($0 is Boom)
        }
        XCTAssertEqual(metrics.drain().observations.first?.fires, 1)
    }

    func testMeasureWriteCountsAndRethrows() {
        let metrics = StoreMetrics()
        XCTAssertEqual(metrics.measureWrite("w") { 42 }, 42)
        XCTAssertThrowsError(try metrics.measureWrite("w") { () throws -> Int in throw Boom() })
        XCTAssertEqual(metrics.drain().writes.first?.commits, 2)
    }

    func testMeasuredTrackingTimesEachFetchOfALiveObservation() async throws {
        let metrics = StoreMetrics()
        let db = try DatabaseQueue()
        try await db.write { try $0.execute(sql: "CREATE TABLE t (id INTEGER PRIMARY KEY)") }
        let observation = ValueObservation.measuredTracking("tRows", in: metrics) { db in
            try Int.fetchAll(db, sql: "SELECT id FROM t")
        }
        var values = observation.values(in: db).makeAsyncIterator()
        _ = try await values.next()
        try await db.write { try $0.execute(sql: "INSERT INTO t (id) VALUES (1)") }
        let updated = try await values.next()
        XCTAssertEqual(updated, [1])
        let stats = try XCTUnwrap(metrics.drain().observations.first)
        XCTAssertEqual(stats.name, "tRows")
        XCTAssertEqual(stats.fires, 2)
        XCTAssertEqual(stats.rows, 1)
    }
}

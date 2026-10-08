import XCTest
import os
@testable import MatronJournal

final class StoreMetricsReporterTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock(); private var all: [[String]] = []
        func append(_ l: [String]) { lock.lock(); all.append(l); lock.unlock() }
        var batches: [[String]] { lock.lock(); defer { lock.unlock() }; return all }
    }

    func testATickLogsTheWindowAndDrainsIt() {
        let metrics = StoreMetrics(); let lines = Lines()
        let reporter = StoreMetricsReporter(metrics: metrics, sink: lines.append)
        metrics.recordFetch("conversationsStream", duration: .milliseconds(2), rows: 3)
        reporter.tick()
        reporter.tick()
        XCTAssertEqual(lines.batches, [["observe conversationsStream fires=1 total_ms=2.0 max_ms=2.0 rows=3"]])
    }

    /// `.info` stays in memory and never reaches `log show`, so a 24 h
    /// measurement run would read back nothing.
    func testLinesAreLoggedAtALevelThatPersists() {
        XCTAssertEqual(StoreMetricsReporter.logLevel, .default)
    }

    func testAnIdleWindowLogsNothing() {
        let lines = Lines()
        StoreMetricsReporter(metrics: StoreMetrics(), sink: lines.append).tick()
        XCTAssertTrue(lines.batches.isEmpty)
    }

    /// Two starts must leave one timer: if the second start leaked another,
    /// `stop()` would cancel only the stored one and the leak would keep
    /// reporting.
    func testStartIsIdempotentAndStopEndsReporting() {
        let metrics = StoreMetrics(); let lines = Lines()
        let reporter = StoreMetricsReporter(metrics: metrics, interval: .milliseconds(50), sink: lines.append)
        reporter.start(); reporter.start()
        metrics.recordWrite("applyJournal", duration: .milliseconds(1))
        let deadline = Date().addingTimeInterval(2)
        while lines.batches.isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        XCTAssertEqual(lines.batches.count, 1, "the timer reports")
        reporter.stop()
        metrics.recordWrite("applyJournal", duration: .milliseconds(1))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(lines.batches.count, 1, "nothing reports after stop")
    }
}

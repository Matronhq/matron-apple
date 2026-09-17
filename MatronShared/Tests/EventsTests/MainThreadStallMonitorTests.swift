import XCTest
@testable import MatronModels

final class MainThreadStallMonitorTests: XCTestCase {
    func testThresholdRule() {
        XCTAssertFalse(MainThreadStallMonitor.isStall(hop: 0.249, threshold: 0.25))
        XCTAssertTrue(MainThreadStallMonitor.isStall(hop: 0.25, threshold: 0.25))
    }

    /// Blocks the main thread for a second under a running monitor and expects
    /// exactly that stall to be reported — and nothing while idle. The block is
    /// several times `unresponsiveAfter` so a utility queue that a loaded runner
    /// schedules a few hundred ms late still announces it while it is happening
    /// (CodeRabbit, PR #224).
    @MainActor
    func testReportsABlockedMainThreadAndStaysQuietWhenIdle() async throws {
        let monitor = MainThreadStallMonitor()
        let stalls = StallBox()
        let announced = StallBox()
        monitor.start(interval: 0.05, threshold: 0.2, unresponsiveAfter: 0.3,
                      onUnresponsive: { announced.append(0) }) { stalls.append($0) }
        defer { monitor.stop() }

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(stalls.values, [], "an idle main thread must not be reported")

        Thread.sleep(forTimeInterval: 1.0)
        try await Task.sleep(nanoseconds: 300_000_000)
        let reported = stalls.values
        XCTAssertEqual(reported.count, 1, "one block, one report: \(reported)")
        XCTAssertGreaterThan(reported.first ?? 0, 0.3, "the report carries the stall's duration")
        XCTAssertEqual(announced.values.count, 1, "a block longer than unresponsiveAfter is announced once, while it is happening")
    }
}

private final class StallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TimeInterval] = []
    func append(_ value: TimeInterval) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return stored }
}

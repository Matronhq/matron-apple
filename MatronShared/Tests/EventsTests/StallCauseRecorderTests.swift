import XCTest
@testable import MatronModels

final class StallCauseRecorderTests: XCTestCase {
    func testSummarisesTheNotesInsideTheWindowMostFrequentFirst() {
        let recorder = StallCauseRecorder(capacity: 16)
        recorder.note("Early.thing", at: 100)
        recorder.note("ChatList.groups", at: 1_000)
        recorder.note("Window.body", at: 1_100)
        recorder.note("ChatList.groups", at: 1_200)
        recorder.note("Late.thing", at: 5_000)

        XCTAssertEqual(recorder.summary(from: 1_000, to: 2_000), "ChatList.groups×2, Window.body×1")
    }

    func testAnEmptyWindowSaysSo() {
        let recorder = StallCauseRecorder(capacity: 4)
        recorder.note("ChatList.groups", at: 10)
        XCTAssertEqual(recorder.summary(from: 20, to: 30), "nothing recorded")
    }

    /// A fixed ring: a burst longer than the capacity keeps the newest
    /// notes and says how many it lost from the window.
    func testAFullRingKeepsTheNewestNotes() {
        let recorder = StallCauseRecorder(capacity: 4)
        for t in 1...6 { recorder.note(t <= 2 ? "Old" : "New", at: UInt64(t)) }
        XCTAssertEqual(recorder.summary(from: 0, to: 10), "New×4 (+ older notes overwritten)")
    }

    func testATallyCountsEveryNoteBetweenItsEnds() {
        let recorder = StallCauseRecorder(capacity: 2)
        recorder.note("Before", at: 1)
        recorder.beginTally()
        for t in 2...6 { recorder.note("During", at: UInt64(t)) }
        XCTAssertEqual(recorder.endTally(), ["During": 5])
        recorder.note("After", at: 7)
        XCTAssertEqual(recorder.endTally(), [:])
    }

    /// The monitor names what was recorded around the stall it reports.
    @MainActor
    func testTheMonitorExplainsAStallWithTheNotesAroundIt() async throws {
        let recorder = StallCauseRecorder(capacity: 64)
        let monitor = MainThreadStallMonitor(causes: recorder)
        let explained = ExplainedBox()
        monitor.start(interval: 0.05, threshold: 0.2, unresponsiveAfter: 5,
                      onStallExplained: { explained.append($1) })
        defer { monitor.stop() }
        try await Task.sleep(nanoseconds: 200_000_000)

        recorder.note("Items.sections")
        Thread.sleep(forTimeInterval: 0.4)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(explained.values, ["Items.sections×1"])
    }
}

private final class ExplainedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

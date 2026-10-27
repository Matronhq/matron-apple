import XCTest
@testable import MatronViewModels

/// The Mac's capture session reports a finished file through a delegate
/// AVFoundation calls on the main thread. Its stop used to wait for that on
/// the main thread (a semaphore), so the callback couldn't run until the
/// wait timed out: every voice note froze the app for 3 s on send.
@MainActor
final class RecordingFinishSignalTests: XCTestCase {
    func test_wait_onTheMainActor_returnsAsSoonAsAMainQueueFinishArrives() async {
        let signal = RecordingFinishSignal()
        let began = Date()
        // Where AVFoundation delivers `didFinishRecordingTo`.
        DispatchQueue.main.async { signal.signal() }

        let finished = await signal.wait(timeout: 3)

        XCTAssertTrue(finished)
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "the wait must not hold the main thread")
    }

    func test_wait_afterTheFinish_returnsAtOnce() async {
        let signal = RecordingFinishSignal()
        signal.signal()
        let finished = await signal.wait(timeout: 3)
        XCTAssertTrue(finished)
    }

    func test_wait_givesUpAfterTheTimeout() async {
        let signal = RecordingFinishSignal()
        let began = Date()
        let finished = await signal.wait(timeout: 0.1)
        XCTAssertFalse(finished)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), 0.1)
    }

    func test_everyWaiterIsReleasedByOneFinish() async {
        let signal = RecordingFinishSignal()
        async let first = signal.wait(timeout: 3)
        async let second = signal.wait(timeout: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { signal.signal() }
        let results = await [first, second]
        XCTAssertEqual(results, [true, true])
    }
}

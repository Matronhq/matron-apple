import Foundation
import XCTest

/// Ends the test process, naming the test, when one test runs far longer
/// than it ever should.
///
/// `swift test` has no per-test time limit (xcodebuild's
/// `-test-timeouts-enabled` has no `swift test` equivalent), so an `await`
/// that never resumes leaves the whole run sitting at 0% CPU with no hint
/// of which test is stuck. The watchdog runs on a background queue, so it
/// still fires when the stuck test holds the main actor.
///
/// Usage: `watchdog = TestHangWatchdog(test: name)` in `setUp()`,
/// `watchdog?.cancel()` in `tearDown()`.
final class TestHangWatchdog: @unchecked Sendable {
    private let work: DispatchWorkItem

    init(test name: String, limit: TimeInterval = 60) {
        work = DispatchWorkItem {
            let message = "\(name) has not finished after \(Int(limit)) s; it is stuck. Ending the test run.\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(1)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + limit, execute: work)
    }

    func cancel() { work.cancel() }
}

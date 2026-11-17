#if os(macOS)
import XCTest
@testable import MatronMac

/// The quiet period around a planned stop and return. The chat list ends it
/// from its own `.running`, and rewrites the Dock badge only when that ends a
/// quiet period (the app just came back).
@MainActor
final class QuietReconnectTests: XCTestCase {
    func testPlannedStopIsQuietWithNoDelayEpisode() {
        let quiet = QuietReconnect()
        quiet.stopped()
        XCTAssertTrue(quiet.isQuiet)
        XCTAssertEqual(quiet.episode, 0)
    }

    func testEachPlannedReconnectStartsANewEpisode() {
        let quiet = QuietReconnect()
        quiet.reconnectStarted()
        let first = quiet.episode
        XCTAssertNotEqual(first, 0)
        quiet.settled()
        quiet.reconnectStarted()
        XCTAssertNotEqual(quiet.episode, first, "the banner's delay timer restarts")
    }

    func testRunningAfterAReturnEndsTheQuietPeriodAndReportsIt() {
        let quiet = QuietReconnect()
        quiet.stopped()
        quiet.reconnectStarted()
        XCTAssertTrue(quiet.runningReached(), "a return: the Dock badge is rewritten from the app's own count")
        XCTAssertFalse(quiet.isQuiet)
        XCTAssertEqual(quiet.episode, 0)
    }

    func testRunningWithNoQuietPeriodReportsNothing() {
        let quiet = QuietReconnect()
        XCTAssertFalse(quiet.runningReached(), "a plain `.running` (first launch, a real drop) leaves the badge alone")
        XCTAssertFalse(quiet.isQuiet)
    }

    func testRunningReachedOnlyReportsOnce() {
        let quiet = QuietReconnect()
        quiet.reconnectStarted()
        XCTAssertTrue(quiet.runningReached())
        XCTAssertFalse(quiet.runningReached())
    }
}
#endif

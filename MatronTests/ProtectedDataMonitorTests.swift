import XCTest
@testable import Matron

/// `ProtectedDataMonitor.resolve`: when a re-read of the system flag may
/// override the lock warning. The regression it pins: a lock and unlock
/// inside the warning window, with the did-become-available post missed,
/// left search unavailable for up to a minute in the foreground.
final class ProtectedDataMonitorTests: XCTestCase {
    private let now = ContinuousClock.now

    func testSystemUnavailableAlwaysWins() {
        let decision = ProtectedDataMonitor.resolve(systemAvailable: false, warnedAt: nil,
                                                    now: now, sceneIsActive: true)
        XCTAssertEqual(decision.available, false)
        XCTAssertTrue(decision.clearWarning)
    }

    func testActiveSceneTrustsTheSystemFlagInsideTheWarningWindow() {
        let decision = ProtectedDataMonitor.resolve(systemAvailable: true,
                                                    warnedAt: now - .seconds(5),
                                                    now: now, sceneIsActive: true)
        XCTAssertEqual(decision.available, true, "an active scene means the device is unlocked")
        XCTAssertTrue(decision.clearWarning)
    }

    func testBackgroundInsideTheWarningWindowLeavesStateAlone() {
        // The system flag still reads true for ~10 s after the warning,
        // while the key is about to go; a background re-read must not
        // reopen the index then.
        let decision = ProtectedDataMonitor.resolve(systemAvailable: true,
                                                    warnedAt: now - .seconds(5),
                                                    now: now, sceneIsActive: false)
        XCTAssertNil(decision.available)
        XCTAssertFalse(decision.clearWarning)
    }

    func testBackgroundPastTheWarningWindowTrustsTheSystemFlag() {
        let decision = ProtectedDataMonitor.resolve(
            systemAvailable: true,
            warnedAt: now - ProtectedDataMonitor.warningWindow - .seconds(1),
            now: now, sceneIsActive: false)
        XCTAssertEqual(decision.available, true)
        XCTAssertTrue(decision.clearWarning)
    }

    func testNoWarningTrustsTheSystemFlag() {
        let decision = ProtectedDataMonitor.resolve(systemAvailable: true, warnedAt: nil,
                                                    now: now, sceneIsActive: false)
        XCTAssertEqual(decision.available, true)
    }
}

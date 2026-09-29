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

    /// Bugbot round 4 "Sign-in can hang after lock": the wait used to depend
    /// on a notification (or a signed-in-only refresh) that may never come.
    /// It now re-reads the system flag itself.
    @MainActor
    func testWaitReReadsTheSystemFlagWithoutANotification() async {
        let system = Box(false)
        let monitor = ProtectedDataMonitor(systemAvailable: { system.value },
                                           sceneIsActive: { false },
                                           pollInterval: .milliseconds(20))
        XCTAssertFalse(monitor.isAvailable)
        let waiter = Task { await monitor.waitUntilAvailable() }
        try? await Task.sleep(for: .milliseconds(100))
        system.value = true // unlocked; no notification is posted
        await waiter.value
        XCTAssertTrue(monitor.isAvailable)
    }

    @MainActor
    func testWaitReturnsAtOnceWhenAvailable() async {
        let monitor = ProtectedDataMonitor(systemAvailable: { true }, sceneIsActive: { true },
                                           pollInterval: .seconds(60))
        await monitor.waitUntilAvailable()
        XCTAssertTrue(monitor.isAvailable)
    }

    func testNoWarningTrustsTheSystemFlag() {
        let decision = ProtectedDataMonitor.resolve(systemAvailable: true, warnedAt: nil,
                                                    now: now, sceneIsActive: false)
        XCTAssertEqual(decision.available, true)
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool
    init(_ value: Bool) { _value = value }
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

import XCTest
@testable import MatronJournal

/// The Mac socket lifecycle: open while a window can be seen, closed after a
/// grace period once none can (or at once on sleep), reopened from the cursor
/// when one is visible again. The process is kept out of App Nap exactly
/// while the socket is open, so a dropped socket is still noticed.
final class SocketLifecyclePolicyTests: XCTestCase {
    private func make(visible: Bool = true) -> SocketLifecyclePolicy {
        SocketLifecyclePolicy(grace: 60, windowsVisible: visible, now: 0)
    }

    func testVisibleWindowKeepsSocketOpenIndefinitely() {
        var policy = make()
        XCTAssertEqual(policy.decide(at: 0), .keep)
        XCTAssertEqual(policy.decide(at: 100_000), .keep)
        XCTAssertTrue(policy.holdsActivity)
        XCTAssertNil(policy.nextDeadline)
    }

    func testHiddenWithinGraceKeepsAndAtGraceCloses() {
        var policy = make()
        policy.setWindowsVisible(false, at: 10)
        XCTAssertEqual(policy.decide(at: 69.9), .keep)
        XCTAssertEqual(policy.decide(at: 70), .close)
    }

    func testCloseIsHandedOutOnce() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        XCTAssertEqual(policy.decide(at: 60), .close)
        XCTAssertEqual(policy.decide(at: 61), .keep)
        XCTAssertEqual(policy.decide(at: 5_000), .keep)
    }

    func testReturningWithinGraceCancelsTheClose() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        XCTAssertEqual(policy.decide(at: 30), .keep)
        policy.setWindowsVisible(true, at: 30)
        XCTAssertEqual(policy.decide(at: 31), .keep, "never closed, so nothing to reconnect")
        XCTAssertNil(policy.nextDeadline)
        // The grace starts over on the next hide.
        policy.setWindowsVisible(false, at: 40)
        XCTAssertEqual(policy.decide(at: 99), .keep)
        XCTAssertEqual(policy.decide(at: 100), .close)
    }

    func testReturningAfterCloseReconnectsFromCursorOnce() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        XCTAssertEqual(policy.decide(at: 60), .close)
        policy.setWindowsVisible(true, at: 500)
        XCTAssertEqual(policy.decide(at: 500), .reconnectFromCursor)
        XCTAssertEqual(policy.decide(at: 501), .keep)
        XCTAssertTrue(policy.holdsActivity)
    }

    func testSleepClosesAtOnceEvenWithAVisibleWindow() {
        var policy = make()
        policy.setAsleep(true, at: 5)
        XCTAssertEqual(policy.decide(at: 5), .close)
        XCTAssertFalse(policy.holdsActivity)
    }

    func testSleepDuringGraceClosesBeforeTheDeadline() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setAsleep(true, at: 10)
        XCTAssertEqual(policy.decide(at: 10), .close)
        XCTAssertNil(policy.nextDeadline)
    }

    func testWakeWithAVisibleWindowReconnectsFromCursor() {
        var policy = make()
        policy.setAsleep(true, at: 5)
        XCTAssertEqual(policy.decide(at: 5), .close)
        policy.setAsleep(false, at: 3_600)
        XCTAssertEqual(policy.decide(at: 3_600), .reconnectFromCursor)
        XCTAssertTrue(policy.holdsActivity)
    }

    func testWakeWithNothingVisibleStaysClosed() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setAsleep(true, at: 10)
        XCTAssertEqual(policy.decide(at: 10), .close)
        policy.setAsleep(false, at: 20)
        XCTAssertEqual(policy.decide(at: 20), .keep, "a dark wake must not open a socket")
        XCTAssertFalse(policy.holdsActivity)
    }

    func testShowingAWindowWhileAsleepWaitsForWake() {
        var policy = make()
        policy.setAsleep(true, at: 0)
        XCTAssertEqual(policy.decide(at: 0), .close)
        policy.setWindowsVisible(false, at: 1)
        policy.setWindowsVisible(true, at: 2)
        XCTAssertEqual(policy.decide(at: 2), .keep)
        policy.setAsleep(false, at: 3)
        XCTAssertEqual(policy.decide(at: 3), .reconnectFromCursor)
    }

    func testActivityIsHeldThroughTheGraceSoTheCloseTimerFires() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        XCTAssertTrue(policy.holdsActivity, "an idle process would throttle the timer that closes the socket")
        XCTAssertEqual(policy.nextDeadline, 60)
        XCTAssertEqual(policy.decide(at: 60), .close)
        XCTAssertFalse(policy.holdsActivity, "closed: the Mac may idle")
    }

    func testStartingHiddenClosesAfterGrace() {
        var policy = SocketLifecyclePolicy(grace: 60, windowsVisible: false, now: 100)
        XCTAssertEqual(policy.nextDeadline, 160)
        XCTAssertEqual(policy.decide(at: 159), .keep)
        XCTAssertEqual(policy.decide(at: 160), .close)
    }

    func testRepeatedSameValuesDoNotRestartTheGrace() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setWindowsVisible(false, at: 50)
        XCTAssertEqual(policy.decide(at: 60), .close)
    }
}

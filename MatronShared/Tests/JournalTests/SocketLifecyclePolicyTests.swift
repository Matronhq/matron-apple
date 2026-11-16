import XCTest
@testable import MatronJournal

/// The Mac socket lifecycle: open while a window can be seen, closed after a
/// grace period once none can (or at once on sleep), reopened from the cursor
/// when one is visible again. With no window on screen, an open socket holds
/// an activity assertion so a dropped one is still noticed; a visible window
/// keeps the app awake on its own.
final class SocketLifecyclePolicyTests: XCTestCase {
    private func make(visible: Bool = true) -> SocketLifecyclePolicy {
        SocketLifecyclePolicy(grace: 60, windowsVisible: visible, now: 0)
    }

    func testVisibleWindowKeepsSocketOpenIndefinitely() {
        var policy = make()
        XCTAssertEqual(policy.decide(at: 0), .keep)
        XCTAssertEqual(policy.decide(at: 100_000), .keep)
        XCTAssertFalse(policy.holdsActivity, "a window on screen keeps the app out of App Nap itself")
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
        XCTAssertFalse(policy.holdsActivity)
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

    // MARK: Activation

    func testActivationAloneWantsTheSocketBeforeAnyWindowIsDrawn() {
        var policy = make(visible: false)
        XCTAssertEqual(policy.decide(at: 60), .close)
        policy.setAppActive(true, at: 500)
        XCTAssertEqual(policy.decide(at: 500), .reconnectFromCursor)
        XCTAssertTrue(policy.holdsActivity, "no window yet: the assertion covers the open socket")
        policy.setWindowsVisible(true, at: 501)
        XCTAssertEqual(policy.decide(at: 501), .keep)
        XCTAssertFalse(policy.holdsActivity)
    }

    func testActivationAloneDoesNotOutlastTheActivationWindow() {
        var policy = SocketLifecyclePolicy(grace: 60, windowsVisible: false, now: 0)
        XCTAssertEqual(policy.decide(at: 60), .close)
        policy.setAppActive(true, at: 500)
        XCTAssertEqual(policy.decide(at: 500), .reconnectFromCursor)
        XCTAssertEqual(policy.nextDeadline, 505)
        XCTAssertEqual(policy.decide(at: 504.9), .keep)
        XCTAssertEqual(policy.decide(at: 505), .close, "active, but no window ever showed")
        XCTAssertFalse(policy.holdsActivity)
    }

    func testClosingTheLastWindowWhileStillActiveClosesAfterTheGrace() {
        var policy = make()
        policy.setAppActive(true, at: 0)
        policy.setWindowsVisible(false, at: 100) // red button; Matron stays frontmost
        XCTAssertEqual(policy.nextDeadline, 160)
        XCTAssertEqual(policy.decide(at: 159), .keep)
        XCTAssertEqual(policy.decide(at: 160), .close, "appActive stays true, windowsVisible alone decides")
        XCTAssertFalse(policy.holdsActivity)
    }

    func testMinimisingWhileActiveStartsTheGraceAtOnce() {
        var policy = make()
        policy.setAppActive(true, at: 0)
        policy.setWindowsVisible(false, at: 1_000)
        XCTAssertEqual(policy.decide(at: 1_030), .keep)
        XCTAssertEqual(policy.decide(at: 1_060), .close)
    }

    func testResigningActiveInsideTheWindowDoesNotShortenTheGrace() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setAppActive(true, at: 10)
        policy.setAppActive(false, at: 11)
        XCTAssertEqual(policy.nextDeadline, 60)
    }

    // MARK: Displays sleeping while the system stays awake

    func testDisplaySleepIsNotSystemSleepSoTheGraceStillApplies() {
        var policy = make()
        policy.setDisplaysAsleep(true, at: 10)
        XCTAssertEqual(policy.decide(at: 10), .keep, "a screen blink must not drop the socket")
        XCTAssertTrue(policy.holdsActivity, "nothing can be seen, so nothing keeps the app awake")
        XCTAssertEqual(policy.nextDeadline, 70)
        XCTAssertEqual(policy.decide(at: 70), .close)
    }

    func testDisplayWakeWithinGraceKeepsTheSocket() {
        var policy = make()
        policy.setDisplaysAsleep(true, at: 10)
        policy.setDisplaysAsleep(false, at: 40)
        XCTAssertEqual(policy.decide(at: 40), .keep)
        XCTAssertNil(policy.nextDeadline)
        XCTAssertFalse(policy.holdsActivity)
    }

    func testDisplayWakeAfterTheCloseReconnects() {
        var policy = make()
        policy.setDisplaysAsleep(true, at: 0)
        XCTAssertEqual(policy.decide(at: 60), .close)
        policy.setDisplaysAsleep(false, at: 3_000)
        XCTAssertEqual(policy.decide(at: 3_000), .reconnectFromCursor)
    }

    func testDisplaysAsleepIsIndependentOfSystemSleep() {
        var policy = make()
        policy.setDisplaysAsleep(true, at: 0)
        policy.setAsleep(true, at: 5)
        XCTAssertEqual(policy.decide(at: 5), .close)
        policy.setAsleep(false, at: 100)
        XCTAssertEqual(policy.decide(at: 100), .keep, "the displays are still asleep")
        policy.setDisplaysAsleep(false, at: 101)
        XCTAssertEqual(policy.decide(at: 101), .reconnectFromCursor)
    }

    // MARK: Voice notes, outbox, stay connected

    func testVoiceNoteKeepsAndOpensTheSocketWhileCovered() {
        var policy = make(visible: false)
        XCTAssertEqual(policy.decide(at: 60), .close)
        policy.setVoiceNoteActive(true, at: 100)
        XCTAssertEqual(policy.decide(at: 100), .reconnectFromCursor)
        XCTAssertTrue(policy.holdsActivity)
        XCTAssertNil(policy.nextDeadline)
        XCTAssertEqual(policy.decide(at: 10_000), .keep, "no grace limit while a note is in flight")
        policy.setVoiceNoteActive(false, at: 10_001)
        XCTAssertEqual(policy.decide(at: 10_001), .close, "delivered: the socket closes without another grace")
    }

    func testVoiceNoteDoesNotOutliveSleep() {
        var policy = make(visible: false)
        policy.setVoiceNoteActive(true, at: 0)
        policy.setAsleep(true, at: 5)
        XCTAssertEqual(policy.decide(at: 5), .close)
    }

    func testOutboxPendingHoldsTheSocketUntilItDrains() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setOutboxPending(true, at: 10)
        XCTAssertEqual(policy.decide(at: 500), .keep)
        XCTAssertNil(policy.nextDeadline)
        policy.setOutboxPending(false, at: 501)
        XCTAssertEqual(policy.decide(at: 501), .close)
    }

    func testOutboxOfflineWithNoNetworkReleasesTheActivityButKeepsTheSocket() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setOutboxPending(true, at: 10)
        XCTAssertEqual(policy.decide(at: 100), .keep, "past the grace, the outbox holds the socket")
        XCTAssertTrue(policy.holdsActivity, "connected or backing off with a network: keep the timers awake")

        policy.setNetworkUnavailable(true, at: 101)
        XCTAssertFalse(policy.holdsActivity, "an outage must not hold App Nap off for as long as it lasts")
        XCTAssertEqual(policy.decide(at: 101), .keep, "the socket is still wanted: the engine retries on its own")
        XCTAssertFalse(policy.socketClosed)

        policy.setNetworkUnavailable(false, at: 400) // the path monitor saw the network return
        XCTAssertTrue(policy.holdsActivity, "back to holding it while it reconnects")
    }

    func testNoNetworkDoesNotReleaseTheActivityDuringTheGrace() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setNetworkUnavailable(true, at: 1)
        XCTAssertTrue(policy.holdsActivity, "nothing holds the socket but the grace: its close timer needs the process awake")
        XCTAssertEqual(policy.decide(at: 60), .close)
        XCTAssertFalse(policy.holdsActivity)
    }

    func testNoNetworkWithAVoiceNoteOrStayConnectedAlsoReleasesTheActivity() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setNetworkUnavailable(true, at: 1)
        policy.setStayConnected(true, at: 2)
        XCTAssertFalse(policy.holdsActivity)
        policy.setStayConnected(false, at: 3)
        policy.setVoiceNoteActive(true, at: 3)
        XCTAssertFalse(policy.holdsActivity)
        policy.setNetworkUnavailable(false, at: 4)
        XCTAssertTrue(policy.holdsActivity)
    }

    func testVoiceNoteTailDoesNotCloseOverAQueuedOutbox() {
        var policy = make()
        policy.setWindowsVisible(false, at: 0)
        policy.setOutboxPending(true, at: 10)   // text queued before hiding
        XCTAssertEqual(policy.decide(at: 100), .keep, "hidden past the grace, the outbox holds it")
        policy.setVoiceNoteActive(true, at: 100)
        XCTAssertEqual(policy.decide(at: 101), .keep)
        policy.setVoiceNoteActive(false, at: 110) // note delivered, tail ended
        XCTAssertFalse(policy.wouldClose(at: 110), "the outbox is still pending")
        XCTAssertEqual(policy.decide(at: 110), .keep)
        policy.setOutboxPending(false, at: 120)
        XCTAssertTrue(policy.wouldClose(at: 120))
        XCTAssertEqual(policy.decide(at: 120), .close)
    }

    func testStayConnectedKeepsTheSocketWhileHidden() {
        var policy = make()
        policy.setStayConnected(true, at: 0)
        policy.setWindowsVisible(false, at: 1)
        XCTAssertEqual(policy.decide(at: 100_000), .keep)
        XCTAssertTrue(policy.holdsActivity, "the user opted in to a socket without a window")
        policy.setStayConnected(false, at: 100_001)
        XCTAssertEqual(policy.decide(at: 100_001), .close)
    }

    // MARK: Invariant

    /// A small deterministic generator (SplitMix64), so a failure replays.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// After any sequence of inputs and a `decide`, a wanted socket is one
    /// the host has told to open and, unless a window on screen keeps the app
    /// awake by itself (or only the user's work holds it while the network is
    /// down), one the host holds an activity assertion for.
    func testWantedSocketAlwaysHasActivityOrAVisibleWindow() {
        var rng = SeededGenerator(state: 0x5EED)
        for _ in 0..<200 {
            var policy = SocketLifecyclePolicy(grace: 60, windowsVisible: Bool.random(using: &rng), now: 0)
            var now: TimeInterval = 0
            for _ in 0..<60 {
                now += TimeInterval(Int.random(in: 0...90, using: &rng))
                let value = Bool.random(using: &rng)
                switch Int.random(in: 0..<9, using: &rng) {
                case 0: policy.setWindowsVisible(value, at: now)
                case 1: policy.setAppActive(value, at: now)
                case 2: policy.setAsleep(value, at: now)
                case 3: policy.setDisplaysAsleep(value, at: now)
                case 4: policy.setVoiceNoteActive(value, at: now)
                case 5: policy.setOutboxPending(value, at: now)
                case 6: policy.setStayConnected(value, at: now)
                case 7: policy.setNetworkUnavailable(value, at: now)
                default: break // time passing alone (the grace deadline)
                }
                _ = policy.decide(at: now)
                if policy.wantsSocket(at: now) {
                    XCTAssertFalse(policy.socketClosed, "wanted but closed after decide: \(policy)")
                    // With the network down, only the user's own work may hold
                    // the socket without an assertion.
                    XCTAssertTrue(policy.holdsActivity || policy.windowKeepsAwake
                                    || (policy.held && policy.networkUnavailable),
                                  "wanted without an assertion or a visible window: \(policy)")
                } else {
                    XCTAssertTrue(policy.socketClosed, "unwanted but open after decide: \(policy)")
                    XCTAssertFalse(policy.holdsActivity, "assertion held with the socket closed: \(policy)")
                }
            }
        }
    }
}

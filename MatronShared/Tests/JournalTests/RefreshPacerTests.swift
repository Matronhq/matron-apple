import XCTest
@testable import MatronJournal

final class RefreshPacerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = ContinuousClock.now
    }

    func testTheFirstRefreshGoesOutAndTheNextWaitsOutTheInterval() {
        let clock = Clock()
        let pacer = RefreshPacer(interval: .seconds(600), activity: AppActivity(), now: { clock.now })
        XCTAssertTrue(pacer.take())
        XCTAssertFalse(pacer.take())
        clock.now += .seconds(599)
        XCTAssertFalse(pacer.take())
        clock.now += .seconds(1)
        XCTAssertTrue(pacer.take())
    }

    func testAKnownChangeSkipsTheInterval() {
        let pacer = RefreshPacer(interval: .seconds(600), activity: AppActivity())
        XCTAssertTrue(pacer.take())
        XCTAssertTrue(pacer.take(changed: true))
    }

    func testNothingGoesOutInTheBackground() {
        let activity = AppActivity(active: false)
        let pacer = RefreshPacer(interval: .zero, activity: activity)
        XCTAssertFalse(pacer.take())
        XCTAssertFalse(pacer.take(changed: true))
        activity.setActive(true)
        XCTAssertTrue(pacer.take())
    }

    func testAResetLetsTheNextRefreshOut() {
        let pacer = RefreshPacer(interval: .seconds(600), activity: AppActivity())
        XCTAssertTrue(pacer.take())
        pacer.reset()
        XCTAssertTrue(pacer.take())
    }

    func testReturningToTheFrontWakesTheSignalOnce() async {
        let activity = AppActivity(active: false)
        let pacer = RefreshPacer(activity: activity)
        var signals = pacer.foregroundSignals().makeAsyncIterator()
        activity.setActive(true)
        activity.setActive(true) // already active: no second wake
        let first: Void? = await signals.next()
        XCTAssertNotNil(first)
        activity.setActive(false)
        activity.setActive(true)
        let second: Void? = await signals.next()
        XCTAssertNotNil(second)
    }
}

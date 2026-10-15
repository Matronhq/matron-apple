import XCTest
import AppKit
import MatronViewModels
@testable import MatronMac

@MainActor
final class MacLiveScrollHoldTests: XCTestCase {
    private final class Owner {}

    func test_aLiveScrollHoldsTheGateUntilEveryScrollViewStops() {
        let gate = LiveUpdateGate(interval: .zero)
        let hold = MacLiveScrollHold()
        hold.install(gate: gate)
        let list = NSScrollView(), chat = NSScrollView()
        let owner = Owner()
        var applied = 0

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: list)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: list)
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: chat)
        XCTAssertTrue(gate.isHeld)
        gate.submit(owner, "a") { applied += 1 }
        XCTAssertEqual(applied, 0)

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: list)
        XCTAssertEqual(applied, 0, "the chat is still scrolling")
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: chat)
        XCTAssertEqual(applied, 1)
        XCTAssertFalse(gate.isHeld)

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: chat)
        XCTAssertFalse(gate.isHeld, "a stray end changes nothing")
    }
}

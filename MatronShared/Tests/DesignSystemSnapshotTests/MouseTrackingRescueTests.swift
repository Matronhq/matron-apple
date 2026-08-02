#if os(macOS)
import AppKit
import SwiftUI
import XCTest
@testable import MatronDesignSystem

/// Pins the mouse-tracking watchdog introduced after the 2026-08-02
/// freeze (AppKit's `mouseDown` selection-tracking loop polling forever
/// for a `mouseUp` it never received, at ~100% CPU, until force quit).
/// The timer body is exercised directly via `fire()` — entering AppKit's
/// real tracking loop headless is not safe, and the `mouseDown` override
/// is a thin arm/disarm around this logic.
@MainActor
final class MouseTrackingRescueTests: XCTestCase {

    private typealias RescueState = MouseTrackingRescueTextView.RescueState

    private func makeState(
        buttonDown: Bool,
        tracking: Bool = true,
        onPost: @escaping (NSEvent) -> Void
    ) -> RescueState {
        let state = RescueState()
        state.isTracking = tracking
        state.leftButtonIsDown = { buttonDown }
        state.postEvent = onPost
        return state
    }

    func test_rescue_postsSyntheticMouseUp_whenButtonUpButStillTracking() {
        var posted: [NSEvent] = []
        let state = makeState(buttonDown: false) { posted.append($0) }

        let timer = MouseTrackingRescueTextView.makeRescueTimer(state: state)
        defer { timer.invalidate() }
        timer.fire()

        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?.type, .leftMouseUp)
        XCTAssertEqual(state.rescueCount, 1)
    }

    func test_rescue_doesNothing_whileButtonIsHeld() {
        var posted: [NSEvent] = []
        let state = makeState(buttonDown: true) { posted.append($0) }

        let timer = MouseTrackingRescueTextView.makeRescueTimer(state: state)
        defer { timer.invalidate() }
        timer.fire()

        XCTAssertTrue(posted.isEmpty, "a genuinely held button is a normal drag — no rescue")
        XCTAssertEqual(state.rescueCount, 0)
    }

    func test_rescue_doesNothing_afterTrackingEnded() {
        var posted: [NSEvent] = []
        let state = makeState(buttonDown: false, tracking: false) { posted.append($0) }

        let timer = MouseTrackingRescueTextView.makeRescueTimer(state: state)
        defer { timer.invalidate() }
        timer.fire()

        XCTAssertTrue(posted.isEmpty, "once super.mouseDown returned the loop exited on its own")
    }

    func test_rescue_keepsReposting_whileWedgePersists() {
        // If the first synthetic event is consumed by something other than
        // the tracking loop, subsequent ticks must try again.
        var posted: [NSEvent] = []
        let state = makeState(buttonDown: false) { posted.append($0) }

        let timer = MouseTrackingRescueTextView.makeRescueTimer(state: state)
        defer { timer.invalidate() }
        timer.fire()
        timer.fire()

        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(state.rescueCount, 2)
    }

    func test_messageBubbleTextView_isRescuable() {
        // The bubble surface is where the freeze hit — pin that a mounted
        // `SelectableMessageText` builds its text view from the
        // rescue-capable subclass rather than plain `NSTextView`.
        let host = NSHostingView(rootView: SelectableMessageText("hello"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        XCTAssertNotNil(
            firstDescendant(ofType: MouseTrackingRescueTextView.self, in: host),
            "SelectableMessageText must mount MouseTrackingRescueTextView"
        )
    }

    private func firstDescendant<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        for sub in root.subviews {
            if let match = sub as? T { return match }
            if let match = firstDescendant(ofType: type, in: sub) { return match }
        }
        return nil
    }
}
#endif

#if os(macOS)
import AppKit
import os

/// `NSTextView` whose `mouseDown` cannot wedge the app.
///
/// AppKit handles a text-view press with a nested tracking loop
/// (`_bellerophonTrackMouse…`) that polls the event queue until it sees
/// the matching `mouseUp`. That event is not guaranteed to arrive: the
/// 2026-08-02 freeze (hang + cpu_resource reports, PID 71461) caught the
/// loop polling at ~100% CPU on the main thread for over three minutes —
/// through a mid-press detail-column remount — until the user force-quit.
/// The loop is private AppKit code, so it can't be exited directly; what
/// CAN run while it polls is anything scheduled in `.eventTracking`
/// run-loop mode.
///
/// `mouseDown` therefore arms a timer in that mode before entering the
/// tracking loop. Each tick checks the physical button state: if the left
/// button is already up but the loop is still tracking, the `mouseUp` was
/// lost — the timer feeds the loop a synthetic one so it exits. A normal
/// click returns in milliseconds and invalidates the timer before it ever
/// fires.
open class MouseTrackingRescueTextView: NSTextView {

    /// State shared between `mouseDown` and the rescue timer. A separate
    /// reference type (rather than captured `self`) so the timer block
    /// stays free of the non-Sendable view under strict concurrency —
    /// every access happens on the main thread (the timer lives on the
    /// main run loop, which is also where the tracking loop polls).
    final class RescueState: @unchecked Sendable {
        /// True while `super.mouseDown` is on the stack.
        var isTracking = false
        /// The window the press started in, captured up front — in the
        /// orphaned-teardown variant the view's `window` is nil by the
        /// time the rescue fires.
        var windowNumber = 0
        /// Rescues attempted for this press — bounds the log noise, and
        /// lets the timer keep re-posting in case one synthetic event
        /// gets consumed by something other than the tracking loop.
        var rescueCount = 0
        /// Seam for tests: physical left-button state.
        var leftButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
        /// Seam for tests: delivery of the synthetic event. `atStart` so
        /// the polling loop dequeues it ahead of anything else pending.
        var postEvent: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }
    }

    private static let logger = Logger(subsystem: "chat.matron", category: "text-tracking-rescue")

    /// Poll period for the watchdog. Long enough to never race a normal
    /// click (those finish in milliseconds and cancel the timer), short
    /// enough that a wedged loop is unstuck before the user reaches for
    /// force-quit.
    static let rescuePollInterval: TimeInterval = 0.25

    /// Test seams, forwarded into each press's `RescueState`.
    var leftButtonIsDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 == 1 }
    var postRescueEvent: (NSEvent) -> Void = { NSApp.postEvent($0, atStart: true) }

    open override func mouseDown(with event: NSEvent) {
        let state = RescueState()
        state.windowNumber = window?.windowNumber ?? 0
        state.leftButtonIsDown = leftButtonIsDown
        state.postEvent = postRescueEvent
        let timer = Self.makeRescueTimer(state: state)
        // `.eventTracking`, not `.common`: this is the mode the nested
        // mouse-tracking loop pumps, so the timer fires even while
        // `super.mouseDown` never returns control to the default mode.
        RunLoop.current.add(timer, forMode: .eventTracking)
        state.isTracking = true
        defer {
            state.isTracking = false
            timer.invalidate()
        }
        super.mouseDown(with: event)
    }

    /// The watchdog itself, factored out so tests can `fire()` it against
    /// a stubbed `RescueState` without entering AppKit's real tracking
    /// loop (which cannot be safely run headless).
    static func makeRescueTimer(state: RescueState) -> Timer {
        Timer(timeInterval: rescuePollInterval, repeats: true) { _ in
            guard state.isTracking, !state.leftButtonIsDown() else { return }
            guard let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSEvent.mouseLocation,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: state.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 0
            ) else { return }
            state.rescueCount += 1
            if state.rescueCount == 1 {
                logger.fault("mouse-tracking rescue: button is up but the tracking loop is still polling — posting synthetic mouseUp (window \(state.windowNumber, privacy: .public))")
            }
            state.postEvent(up)
        }
    }
}
#endif

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
///
/// The same press machinery also SWALLOWS link clicks (Dan, 2026-08-03:
/// "often when you click on links nothing happens" — intermittently, in
/// live chats). The `.link` attribute is present and the delegate policy
/// works when it's consulted, but a press disturbed between its down and
/// up (a streaming delta re-setting the text storage, the timeline
/// shifting the row, a remount) aborts inside AppKit and never reaches
/// `clicked(onLink:at:)`. So `mouseDown` additionally remembers when a
/// press BEGAN on a link; when the press resolves (either press shape —
/// nested tracking loop, or a separate `mouseUp` event) with the button
/// up, no meaningful pointer movement, no selection made, and no link
/// dispatched by AppKit, the view dispatches `clicked(onLink:at:)` itself.
/// AppKit's own dispatch marks the press handled via two redundant hooks
/// (the `clicked(onLink:at:)` override below, and delegates calling
/// `noteLinkClickHandled()`), so the fallback can never double-open.
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
        /// Where the press went down, in WINDOW coordinates — the synthetic
        /// `mouseUp` lands there so the rescued press resolves as the click
        /// the user made. (The first shipped version put `NSEvent.mouseLocation`
        /// — screen coordinates — in the event's window-coordinate field,
        /// which the tracking loop read as a drag to a far-away point and
        /// turned into a phantom selection.)
        var pressLocationInWindow = NSPoint.zero
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
        armLinkPress(for: event)
        let state = RescueState()
        state.windowNumber = window?.windowNumber ?? 0
        state.pressLocationInWindow = event.locationInWindow
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
        // Press shape 1 — the nested tracking loop: `super` consumed the
        // `mouseUp` internally (our `mouseUp` override never runs), so if
        // the button is already up the press is over — resolve it here.
        if !leftButtonIsDown() {
            resolveLinkPressIfNeeded()
        }
    }

    open override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Press shape 2 — no tracking loop: the down returned immediately
        // and the up arrives as its own event.
        resolveLinkPressIfNeeded()
    }

    // MARK: - Swallowed link-click fallback

    /// The press currently in flight that began on a link, if any.
    private struct LinkPress {
        let link: Any
        let charIndex: Int
        let screenPoint: NSPoint
        /// Identifies the storage CONTENT at press time so the resolve log
        /// can report whether a streaming update replaced it mid-press —
        /// the leading suspect for the swallowed clicks.
        let storageHash: Int
        let began: TimeInterval
    }

    private var linkPress: LinkPress?
    /// True once anyone — AppKit or the fallback — dispatched this press's
    /// link. Set redundantly by the `clicked(onLink:at:)` override and by
    /// `noteLinkClickHandled()` so it holds regardless of which internal
    /// route AppKit takes to the delegate.
    private var linkClickDispatched = false

    /// A press that travels farther than this (in screen points) between
    /// down and resolve is a drag, not a click.
    static let linkClickSlop: CGFloat = 3

    /// Seam for tests: the pointer's current screen position.
    var currentScreenLocation: () -> NSPoint = { NSEvent.mouseLocation }

    /// Delegates handling `clickedOnLink` call this so the fallback knows
    /// AppKit consulted them (covers any AppKit path that skips
    /// `clicked(onLink:at:)`).
    public func noteLinkClickHandled() {
        linkClickDispatched = true
    }

    open override func clicked(onLink link: Any, at charIndex: Int) {
        linkClickDispatched = true
        super.clicked(onLink: link, at: charIndex)
    }

    /// Records a press that begins on a link, so its end can check that the
    /// link actually opened. Message bodies only — the composer is editable
    /// (and link-free), and editable views reserve plain clicks for caret
    /// placement anyway. Internal so tests can drive the arm/resolve pair
    /// deterministically — a full `mouseDown` headless flips between
    /// AppKit press paths run to run, so the guards are pinned here.
    func armLinkPress(for event: NSEvent) {
        linkPress = nil
        linkClickDispatched = false
        guard isSelectable, !isEditable,
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let storage = textStorage, storage.length > 0 else { return }
        // Insertion-index hit test (no `layoutManager` access — that would
        // downgrade the view to TextKit 1). At a glyph's trailing half this
        // returns the NEXT character, so presses on a link's last pixel
        // column may not arm — conservative in the same direction AppKit is.
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, index < storage.length,
              let link = storage.attribute(.link, at: index, effectiveRange: nil) else { return }
        linkPress = LinkPress(
            link: link,
            charIndex: index,
            screenPoint: currentScreenLocation(),
            storageHash: storage.string.hashValue,
            began: ProcessInfo.processInfo.systemUptime
        )
    }

    /// Called when a press that began on a link is over. If it stayed a
    /// click (button up, pointer within slop, no selection created) and
    /// nobody dispatched the link, the click was swallowed — dispatch it.
    /// Internal for tests — see `armLinkPress`.
    func resolveLinkPressIfNeeded() {
        guard let press = linkPress else { return }
        linkPress = nil
        guard !linkClickDispatched else { return }
        let here = currentScreenLocation()
        let moved = hypot(here.x - press.screenPoint.x, here.y - press.screenPoint.y)
        guard moved <= Self.linkClickSlop, selectedRange().length == 0 else { return }
        let storageChanged = textStorage?.string.hashValue != press.storageHash
        let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - press.began) * 1000)
        let url = press.link as? URL
        Self.logger.notice("link click swallowed by AppKit — dispatching fallback (scheme \(url?.scheme ?? "?", privacy: .public), host \(url?.host ?? "?", privacy: .public), \(elapsedMs)ms, storageChanged \(storageChanged), moved \(String(format: "%.1f", moved), privacy: .public)pt)")
        // Clamp: a mid-press storage replacement can shrink the text below
        // the pressed index. The LINK value is what matters downstream.
        let safeIndex = min(press.charIndex, max(0, (textStorage?.length ?? 1) - 1))
        clicked(onLink: press.link, at: safeIndex)
    }

    /// The watchdog itself, factored out so tests can `fire()` it against
    /// a stubbed `RescueState` without entering AppKit's real tracking
    /// loop (which cannot be safely run headless).
    static func makeRescueTimer(state: RescueState) -> Timer {
        Timer(timeInterval: rescuePollInterval, repeats: true) { _ in
            guard state.isTracking, !state.leftButtonIsDown() else { return }
            guard let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: state.pressLocationInWindow,
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

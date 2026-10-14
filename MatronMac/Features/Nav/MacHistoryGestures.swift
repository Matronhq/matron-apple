import AppKit
import SwiftUI

/// Which way a mouse button or swipe moves through the window's history.
enum MacHistoryStep: Equatable {
    case back
    case forward

    /// A mouse's own Back / Forward buttons (buttons 4 and 5, numbered
    /// from 0 by AppKit as 3 and 4), as browsers and Finder read them.
    static func forMouseButton(_ buttonNumber: Int) -> MacHistoryStep? {
        switch buttonNumber {
        case 3: return .back
        case 4: return .forward
        default: return nil
        }
    }

    /// A three-finger swipe (`NSEvent.EventType.swipe`), when the trackpad
    /// is set to swipe between pages with three fingers: a swipe to the
    /// right goes back, as in Safari. `deltaX` is positive for that.
    static func forSwipe(deltaX: CGFloat) -> MacHistoryStep? {
        if deltaX > 0 { return .back }
        if deltaX < 0 { return .forward }
        return nil
    }

    /// Where a finished two-finger page swipe lands: a positive amount is
    /// the page pulled to the right, which goes back.
    static func forTrackedSwipe(amount: CGFloat) -> MacHistoryStep? {
        if amount > 0 { return .back }
        if amount < 0 { return .forward }
        return nil
    }

    /// Whether a scroll event starts a two-finger page swipe: the start of
    /// a trackpad gesture that is mostly sideways, with the system's
    /// "Swipe between pages" on, and nothing under the pointer that
    /// scrolls sideways itself (a wide code block or table keeps its own
    /// horizontal scroll).
    static func startsPageSwipe(phase: NSEvent.Phase, deltaX: CGFloat, deltaY: CGFloat,
                                swipeTrackingEnabled: Bool, overHorizontalScroller: Bool) -> Bool {
        phase == .began && swipeTrackingEnabled && !overHorizontalScroller && abs(deltaX) > abs(deltaY)
    }
}

/// The window's Back/Forward on the mouse's side buttons and on trackpad
/// swipes, alongside the toolbar chevrons and ⌘[ / ⌘]. One local event
/// monitor per window, acting only on that window's events, so each
/// window keeps its own history.
struct MacHistoryGestures: ViewModifier {
    let history: MacNavigationHistory
    let goBack: () -> Void
    let goForward: () -> Void

    @State private var monitor = MacHistoryGestureMonitor()

    func body(content: Content) -> some View {
        content
            .background(WindowAccessor { window in monitor.window = window })
            .onAppear {
                monitor.history = history
                monitor.goBack = goBack
                monitor.goForward = goForward
                monitor.start()
            }
            .onDisappear { monitor.stop() }
    }
}

@MainActor
final class MacHistoryGestureMonitor {
    weak var window: NSWindow?
    weak var history: MacNavigationHistory?
    private var canGoBack: Bool { history?.canGoBack ?? false }
    private var canGoForward: Bool { history?.canGoForward ?? false }
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window, window.attachedSheet == nil else { return event }
        switch event.type {
        case .otherMouseDown:
            guard let step = MacHistoryStep.forMouseButton(event.buttonNumber) else { return event }
            perform(step)
            return nil
        case .swipe:
            guard let step = MacHistoryStep.forSwipe(deltaX: event.deltaX) else { return event }
            perform(step)
            return nil
        case .scrollWheel:
            trackPageSwipe(event, in: window)
            return event
        default:
            return event
        }
    }

    private func perform(_ step: MacHistoryStep) {
        switch step {
        case .back: if canGoBack { goBack() }
        case .forward: if canGoForward { goForward() }
        }
    }

    /// A two-finger sideways swipe, tracked the way Safari's page swipe is.
    private func trackPageSwipe(_ event: NSEvent, in window: NSWindow) {
        guard canGoBack || canGoForward,
              MacHistoryStep.startsPageSwipe(phase: event.phase, deltaX: event.scrollingDeltaX,
                                             deltaY: event.scrollingDeltaY,
                                             swipeTrackingEnabled: NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                                             overHorizontalScroller: Self.horizontalScroller(at: event, in: window))
        else { return }
        var landed: MacHistoryStep?
        // Positive amounts pull toward Back; a bound of 0 stops the swipe
        // in a direction with nowhere to go.
        event.trackSwipeEvent(options: [.lockDirection, .clampGestureAmount],
                              dampenAmountThresholdMin: canGoForward ? -1 : 0,
                              max: canGoBack ? 1 : 0) { [weak self] amount, phase, isComplete, _ in
            MainActor.assumeIsolated {
                if phase == .ended { landed = MacHistoryStep.forTrackedSwipe(amount: amount) }
                if phase == .cancelled { landed = nil }
                if isComplete, let landed { self?.perform(landed) }
            }
        }
    }

    /// Whether the view under the pointer sits in a scroll view that can
    /// scroll sideways.
    private static func horizontalScroller(at event: NSEvent, in window: NSWindow) -> Bool {
        guard let content = window.contentView,
              var view = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        while true {
            if let scroll = view as? NSScrollView, let document = scroll.documentView,
               document.frame.width > scroll.contentView.bounds.width + 1 {
                return true
            }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }
}

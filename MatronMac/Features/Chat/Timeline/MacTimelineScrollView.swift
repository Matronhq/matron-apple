import AppKit

/// An `NSScrollView` that tells its owner when the *user* moved the clip
/// origin — via trackpad, mouse wheel, or a scroller-knob drag — as
/// distinct from a programmatic write the controller made itself.
///
/// `TimelineSession` uses this distinction to release follow-tail the
/// moment a user starts scrolling and re-arm it once the user's gesture
/// settles — AFTER its momentum, never at the finger lift. "Began" may be
/// reported more than once per gesture (a wheel phase and a live-scroll
/// notification; `userDragBegan` is idempotent); "ended" at most once.
final class MacTimelineScrollView: NSScrollView {
    var onUserScrollBegan: (() -> Void)?
    var onUserScrollEnded: (() -> Void)?
    var onUserScrolled: ((CGFloat) -> Void)?       // clip origin.y after a user-driven move
    /// Set by the controller around its own origin writes.
    var isApplyingProgrammaticScroll = false

    private var boundsObserver: NSObjectProtocol?
    private var liveScrollBeganObserver: NSObjectProtocol?
    private var liveScrollEndedObserver: NSObjectProtocol?

    /// A trackpad touch-down with no motion yet (`.mayBegin`) doesn't itself
    /// count as a user scroll; if the very next event is `.changed` with no
    /// `.began` in between (the gesture claimed the sequence at touch-down),
    /// that's the point the drag actually starts.
    private var awaitingBeganAfterMayBegin = false

    /// A finger lift (`phase.ended`) is not the end of the user's scroll
    /// when momentum follows — and AppKit gives no forward signal that it
    /// will. So the lift only arms this: a `momentumPhase.began` inside the
    /// grace cancels it (the momentum's own end reports instead), otherwise
    /// it fires "ended". Re-arming follow-tail at the lift let the momentum
    /// carry the reader up while the next stream delta snapped them back.
    private var deferredEnd: DispatchWorkItem?
    /// A "began" has been reported and its "ended" not yet: every "ended"
    /// goes through `reportEnded`, which reports at most one per gesture
    /// (a lift, DidEnd and the momentum's end can all close the same one).
    private var isGestureOpen = false
    /// Two display frames: momentum's `began` follows the lift within the
    /// same event burst (a few ms), so this only delays a no-momentum end.
    static let momentumGrace: TimeInterval = 2.0 / 60.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        contentView.postsBoundsChangedNotifications = true

        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: nil
        ) { [weak self] _ in
            guard let self, !self.isApplyingProgrammaticScroll else { return }
            self.onUserScrolled?(self.contentView.bounds.origin.y)
        }

        liveScrollBeganObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification,
            object: self,
            queue: nil
        ) { [weak self] _ in
            self?.cancelDeferredEnd()
            self?.reportBegan()
        }

        // `didEndLiveScroll` is NOT a safe "ended" on its own. The 10.9
        // AppKit release notes (read) say an animated scroll's DidEnd "is
        // not sent until the animation completes" and that under Responsive
        // Scrolling consecutive gestures share one WillStart/DidEnd pair —
        // i.e. after momentum. But observed here (2026-09-29, macOS 26, the
        // synthetic wheel events of `MacTimelineScrollViewTests`, which are
        // not responsive scrolling): `super.scrollWheel` posts DidEnd
        // SYNCHRONOUSLY on the `phase.ended` event, before any momentum
        // event exists. So it is treated exactly like a finger lift: it
        // arms the deferred end, which momentum cancels.
        liveScrollEndedObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: nil
        ) { [weak self] _ in
            self?.scheduleDeferredEnd()
        }
    }

    deinit {
        deferredEnd?.cancel()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let liveScrollBeganObserver { NotificationCenter.default.removeObserver(liveScrollBeganObserver) }
        if let liveScrollEndedObserver { NotificationCenter.default.removeObserver(liveScrollEndedObserver) }
    }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let isPhaseless = phase.isEmpty && momentumPhase.isEmpty

        // Momentum is the same user scroll carrying on: the lift's deferred
        // "ended" is superseded by the momentum's own end.
        // A new touch-down supersedes it too (its own end reports later).
        if momentumPhase.contains(.began) || phase.contains(.began) || phase.contains(.mayBegin) {
            cancelDeferredEnd()
        }

        if phase.contains(.began) {
            reportBegan()
            awaitingBeganAfterMayBegin = false
        } else if phase.contains(.mayBegin) {
            awaitingBeganAfterMayBegin = true
        } else if phase.contains(.changed) && awaitingBeganAfterMayBegin {
            reportBegan()
            awaitingBeganAfterMayBegin = false
        } else if isPhaseless {
            // A plain mouse wheel tick carries no phase information at all:
            // it is a single, instantaneous user gesture, so began and
            // ended both fire around it.
            reportBegan()
        }

        super.scrollWheel(with: event)

        if isPhaseless {
            cancelDeferredEnd()
            reportEnded()
        } else if phase.contains(.ended) {
            // Finger lift: await momentum (see `deferredEnd`).
            awaitingBeganAfterMayBegin = false
            scheduleDeferredEnd()
        } else if phase.contains(.cancelled) || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
            cancelDeferredEnd()
            reportEnded()
            awaitingBeganAfterMayBegin = false
        }
    }

    private func reportBegan() {
        isGestureOpen = true
        onUserScrollBegan?()
    }

    private func reportEnded() {
        guard isGestureOpen else { return }
        isGestureOpen = false
        onUserScrollEnded?()
    }

    private func scheduleDeferredEnd() {
        cancelDeferredEnd()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredEnd = nil
            self.reportEnded()
        }
        deferredEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.momentumGrace, execute: work)
    }

    private func cancelDeferredEnd() {
        deferredEnd?.cancel()
        deferredEnd = nil
    }
}

import AppKit

/// An `NSScrollView` that tells its owner when the *user* moved the clip
/// origin — via trackpad, mouse wheel, or a scroller-knob drag — as
/// distinct from a programmatic write the controller made itself.
///
/// `TimelineSession` uses this distinction to release follow-tail the
/// moment a user starts scrolling and re-arm it once the user's gesture
/// settles; its `userDragBegan`/`userScrollSettled` calls are idempotent,
/// so this view is free to over-report (e.g. both a wheel phase and a
/// live-scroll notification firing for the same gesture) without harm.
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
            self?.onUserScrollBegan?()
        }

        liveScrollEndedObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification,
            object: self,
            queue: nil
        ) { [weak self] _ in
            self?.onUserScrollEnded?()
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        if let liveScrollBeganObserver { NotificationCenter.default.removeObserver(liveScrollBeganObserver) }
        if let liveScrollEndedObserver { NotificationCenter.default.removeObserver(liveScrollEndedObserver) }
    }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        let momentumPhase = event.momentumPhase
        let isPhaseless = phase.isEmpty && momentumPhase.isEmpty

        if phase.contains(.began) {
            onUserScrollBegan?()
            awaitingBeganAfterMayBegin = false
        } else if phase.contains(.mayBegin) {
            awaitingBeganAfterMayBegin = true
        } else if phase.contains(.changed) && awaitingBeganAfterMayBegin {
            onUserScrollBegan?()
            awaitingBeganAfterMayBegin = false
        } else if isPhaseless {
            // A plain mouse wheel tick carries no phase information at all:
            // it is a single, instantaneous user gesture, so began and
            // ended both fire around it.
            onUserScrollBegan?()
        }

        super.scrollWheel(with: event)

        if isPhaseless {
            onUserScrollEnded?()
        } else if phase.contains(.ended) || phase.contains(.cancelled) || momentumPhase.contains(.ended) {
            onUserScrollEnded?()
            awaitingBeganAfterMayBegin = false
        }
    }
}

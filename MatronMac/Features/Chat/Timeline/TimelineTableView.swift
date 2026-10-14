import AppKit
import QuartzCore

/// The table: reports the end of a window live resize (the full resync),
/// and prepares only what is on screen for a moment after an open or a
/// jump (perf follow-ups O1 (b)).
final class TimelineTableView: NSTableView {
    var onEndLiveResize: (() -> Void)?
    /// The time source for the restriction window (the controller's `clock`).
    var clock: () -> CFTimeInterval = CACurrentMediaTime
    private var restrictedUntil: CFTimeInterval = -.infinity
    /// The last rect AppKit asked to prepare while restricted: prepared once
    /// the window ends, so the overdraw rows still mount, only later.
    private var postponedPreparedRect: NSRect?
    private var isPostponedPrepareScheduled = false

    var isRestrictingPreparedContent: Bool { clock() < restrictedUntil }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    /// For `duration`, `prepareContent(in:)` prepares only `visibleRect`:
    /// the frame that shows an open or a jump mounts the rows on
    /// screen and none of AppKit's overdraw above and below them. Not
    /// permanent: in a steady scroll every prepared row is shown anyway, and
    /// a smaller prepared rect only moves that work into visible frames.
    func restrictPreparedContent(for duration: CFTimeInterval) {
        restrictedUntil = clock() + duration
        schedulePostponedPrepare(after: duration)
    }

    /// The rect the last `prepareContent(in:)` handed to AppKit (test seam:
    /// the table prepares incrementally, so `preparedContentRect` is not it).
    private(set) var lastPreparedRectForTesting: NSRect?

    override func prepareContent(in rect: NSRect) {
        guard isRestrictingPreparedContent else {
            lastPreparedRectForTesting = rect
            super.prepareContent(in: rect)
            return
        }
        postponedPreparedRect = rect
        lastPreparedRectForTesting = visibleRect
        super.prepareContent(in: visibleRect)
    }

    /// One timer at a time; it re-arms for whatever is left when the window
    /// was extended meanwhile (or its clock runs behind the timer's).
    private func schedulePostponedPrepare(after delay: CFTimeInterval) {
        guard !isPostponedPrepareScheduled else { return }
        isPostponedPrepareScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0.001)) { [weak self] in
            guard let self else { return }
            self.isPostponedPrepareScheduled = false
            let remaining = self.restrictedUntil - self.clock()
            if remaining > 0 {
                self.schedulePostponedPrepare(after: remaining)
                return
            }
            guard let rect = self.postponedPreparedRect else { return }
            self.postponedPreparedRect = nil
            // The reader may have scrolled since AppKit asked: what is on
            // screen now is prepared too.
            self.prepareContent(in: rect.union(self.visibleRect))
        }
    }
}

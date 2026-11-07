import UIKit

/// Scrolls the timeline while a text-selection drag is held near its top or
/// bottom edge, and carries the selection on with it. The timeline's text
/// views never scroll themselves, and UIKit doesn't scroll the collection
/// view for them, so without this a selection in a message taller than the
/// screen stopped at the screen's edge.
///
/// A drag counts as a selection drag once the selection in one of the
/// timeline's text views changes while the finger is down and the timeline
/// itself isn't being dragged, and the finger has then moved: a long-press
/// on a word near the edge only selects the word. It scrolls only while
/// that message still has text past the edge, so the selected cell never
/// scrolls away.
@MainActor
final class TimelineSelectionAutoscroller: NSObject, UIGestureRecognizerDelegate {
    /// Sees every touch on the timeline and never recognizes, so it takes
    /// nothing from the text views or the scroll view.
    private final class TouchObserver: UIGestureRecognizer {
        var onTouch: ((UITouch?) -> Void)?
        private weak var tracked: UITouch?

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            guard tracked == nil, let touch = touches.first else { return }
            tracked = touch
            onTouch?(touch)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
            if let tracked, touches.contains(tracked) { onTouch?(tracked) }
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

        private func finish(_ touches: Set<UITouch>) {
            guard let tracked, touches.contains(tracked) else { return }
            self.tracked = nil
            onTouch?(nil)
            state = .failed
        }

        override func reset() {
            super.reset()
            tracked = nil
        }
    }

    /// The band along each edge that scrolls, and the fastest it goes (at
    /// the very edge), in points per frame.
    static let edgeBand: CGFloat = 56
    static let maxSpeed: CGFloat = 14
    /// How far the finger moves after the selection starts before the drag
    /// can scroll.
    static let dragThreshold: CGFloat = 10

    private weak var scrollView: UIScrollView?
    /// The text view holding a selection in the timeline, if any.
    private let selectingTextView: () -> UITextView?
    private let onScrollBegan: () -> Void
    private let onScrollEnded: () -> Void
    private let observer = TouchObserver()
    private var link: CADisplayLink?
    /// The finger, in the scroll view's superview (fixed while it scrolls).
    private var fingerLocation: CGPoint?
    private var selectionAtTouchDown: NSRange?
    private var isSelectionDrag = false
    /// Where the finger was when the selection drag began.
    private var dragOrigin: CGPoint?
    private var hasDragged = false
    private var isScrolling = false

    init(scrollView: UIScrollView, selectingTextView: @escaping () -> UITextView?,
         onScrollBegan: @escaping () -> Void, onScrollEnded: @escaping () -> Void) {
        self.scrollView = scrollView
        self.selectingTextView = selectingTextView
        self.onScrollBegan = onScrollBegan
        self.onScrollEnded = onScrollEnded
        super.init()
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = self
        observer.onTouch = { [weak self] touch in self?.touchChanged(touch) }
        scrollView.addGestureRecognizer(observer)
    }

    func invalidate() {
        stop()
        observer.view?.removeGestureRecognizer(observer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private func touchChanged(_ touch: UITouch?) {
        guard let touch, let scrollView, let host = scrollView.superview else {
            stop()
            fingerLocation = nil
            selectionAtTouchDown = nil
            isSelectionDrag = false
            dragOrigin = nil
            hasDragged = false
            return
        }
        let location = touch.location(in: host)
        if fingerLocation == nil {
            selectionAtTouchDown = selectingTextView()?.selectedRange
        }
        fingerLocation = location
        if !isSelectionDrag, !scrollView.isDragging, let textView = selectingTextView(),
           textView.selectedRange != selectionAtTouchDown {
            isSelectionDrag = true
            dragOrigin = location
        }
        if let dragOrigin, abs(location.y - dragOrigin.y) > Self.dragThreshold { hasDragged = true }
        if isSelectionDrag, hasDragged, !scrollView.isDragging, direction() != 0 {
            start()
        } else {
            stop()
        }
    }

    /// -1 up, 1 down, 0 none, from where the finger is and whether the
    /// selecting text view still runs past that edge.
    private func direction() -> CGFloat {
        guard let scrollView, let host = scrollView.superview, let fingerLocation,
              let textView = selectingTextView() else { return 0 }
        let frame = scrollView.frame
        let text = textView.convert(textView.bounds, to: host)
        if fingerLocation.y > frame.maxY - Self.edgeBand, text.maxY > frame.maxY,
           scrollView.contentOffset.y < maxOffset(scrollView) {
            return 1
        }
        if fingerLocation.y < frame.minY + Self.edgeBand, text.minY < frame.minY,
           scrollView.contentOffset.y > minOffset(scrollView) {
            return -1
        }
        return 0
    }

    private func minOffset(_ scrollView: UIScrollView) -> CGFloat { -scrollView.adjustedContentInset.top }

    private func maxOffset(_ scrollView: UIScrollView) -> CGFloat {
        max(minOffset(scrollView),
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
    }

    private func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        if isScrolling {
            isScrolling = false
            onScrollEnded()
        }
    }

    @objc private func tick() {
        let direction = direction()
        guard direction != 0, let scrollView, let host = scrollView.superview, let fingerLocation,
              let textView = selectingTextView() else { return stop() }
        let frame = scrollView.frame
        let depth = direction > 0 ? fingerLocation.y - (frame.maxY - Self.edgeBand)
                                  : (frame.minY + Self.edgeBand) - fingerLocation.y
        let speed = Self.maxSpeed * min(1, max(0.15, depth / Self.edgeBand))
        let target = min(maxOffset(scrollView), max(minOffset(scrollView), scrollView.contentOffset.y + direction * speed))
        if !isScrolling {
            isScrolling = true
            onScrollBegan()
        }
        scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: target)
        extendSelection(of: textView, to: textView.convert(fingerLocation, from: host), direction: direction)
    }

    /// Moves the selection's leading (scrolling down) or trailing end to the
    /// text under the finger, keeping the other end where it was.
    private func extendSelection(of textView: UITextView, to point: CGPoint, direction: CGFloat) {
        guard let range = textView.selectedTextRange, let position = textView.closestPosition(to: point) else { return }
        let extended: UITextRange?
        if direction > 0 {
            guard textView.compare(position, to: range.end) == .orderedDescending else { return }
            extended = textView.textRange(from: range.start, to: position)
        } else {
            guard textView.compare(position, to: range.start) == .orderedAscending else { return }
            extended = textView.textRange(from: position, to: range.end)
        }
        if let extended { textView.selectedTextRange = extended }
    }
}

#if canImport(UIKit)
import UIKit
import os

/// Pins a vertical timeline's backing `UIScrollView` so it can never pan
/// horizontally. SwiftUI's `ScrollView(.vertical)` derives the backing
/// scroll view's `contentSize` from its content — if any row lays out wider
/// than the viewport, `contentSize.width` exceeds `bounds.width` and UIKit
/// silently enables a horizontal wiggle-with-spring on the whole message
/// list (observed on iPhone, 2026-07-15). SwiftUI offers no per-axis clamp,
/// so this hooks the captured scroll view directly: every `contentSize`
/// write wider than the viewport is clamped back, and the offending
/// descendant views are logged (subsystem `chat.matron`, category
/// `scroll-overflow`) so the too-wide row can be identified from a device
/// log instead of guesswork — the clamp hides the wiggle, not the layout
/// bug.
@MainActor
public final class HorizontalOverflowLock {
    private static let logger = Logger(subsystem: "chat.matron", category: "scroll-overflow")
    /// Sub-point layout jitter is not overflow.
    private static let tolerance: CGFloat = 0.5

    private var observation: NSKeyValueObservation?

    public init(scrollView: UIScrollView) {
        scrollView.alwaysBounceHorizontal = false
        // KVO fires synchronously inside the setter, which UIKit only
        // drives from the main thread — `assumeIsolated` documents that.
        observation = scrollView.observe(\.contentSize) { scrollView, _ in
            MainActor.assumeIsolated {
                Self.clampIfNeeded(scrollView)
            }
        }
        Self.clampIfNeeded(scrollView)
    }

    private static func clampIfNeeded(_ scrollView: UIScrollView) {
        let viewportWidth = scrollView.bounds.width
        // Zero width = pre-layout; clamping now would zero the content.
        guard viewportWidth > 0,
              scrollView.contentSize.width > viewportWidth + tolerance else { return }

        let offenders = overflowingDescendants(of: scrollView, viewportWidth: viewportWidth)
        logger.error("""
            timeline content overflows horizontally: contentSize \
            \(scrollView.contentSize.width, format: .fixed(precision: 1), privacy: .public) \
            > viewport \(viewportWidth, format: .fixed(precision: 1), privacy: .public); \
            offenders: \(offenders.joined(separator: " | "), privacy: .public)
            """)

        // The nested write re-fires the observation; the re-entrant call
        // sees a fitting width and returns.
        scrollView.contentSize.width = viewportWidth
        if scrollView.contentOffset.x != 0 {
            scrollView.contentOffset.x = 0
        }
    }

    /// Descendant views wider than the viewport, as "TypeName widthxheight
    /// @(x,y)" — the diagnosis half of the lock. Does NOT descend into
    /// nested scroll views: a horizontal code-block / diff scroller is
    /// supposed to hold wide content, and its innards would be permanent
    /// false positives. Capped at 8 entries; one wide row usually widens
    /// its whole ancestor chain, and the deepest few name the culprit.
    public static func overflowingDescendants(
        of scrollView: UIScrollView, viewportWidth: CGFloat
    ) -> [String] {
        var report: [String] = []
        func walk(_ view: UIView) {
            for subview in view.subviews {
                guard report.count < 8 else { return }
                if subview.frame.width > viewportWidth + tolerance {
                    let f = subview.frame
                    report.append(String(
                        format: "%@ %.0fx%.0f @(%.0f,%.0f)",
                        String(describing: type(of: subview)),
                        f.width, f.height, f.origin.x, f.origin.y))
                }
                if !(subview is UIScrollView) {
                    walk(subview)
                }
            }
        }
        walk(scrollView)
        return report
    }
}
#endif

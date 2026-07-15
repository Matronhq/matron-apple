import XCTest
import MatronDesignSystem
import UIKit

/// Pins `HorizontalOverflowLock`, the guard that keeps the vertical chat
/// timeline's backing `UIScrollView` from ever panning horizontally. A row
/// that renders wider than the viewport widens the scroll view's
/// `contentSize`, and UIKit then allows a horizontal wiggle with spring —
/// the timeline must clamp that (and log the offending row) instead of
/// letting the whole message list drift sideways.
@MainActor
final class HorizontalOverflowLockTests: XCTestCase {
    private func makeScrollView(width: CGFloat = 320) -> UIScrollView {
        UIScrollView(frame: CGRect(x: 0, y: 0, width: width, height: 600))
    }

    func test_clampsPreexistingOverflowOnInstall() {
        let scrollView = makeScrollView()
        scrollView.contentSize = CGSize(width: 400, height: 1000)

        let lock = HorizontalOverflowLock(scrollView: scrollView)
        defer { _ = lock }

        XCTAssertEqual(scrollView.contentSize.width, 320,
                       "overflowing width clamps to the viewport")
        XCTAssertEqual(scrollView.contentSize.height, 1000,
                       "vertical extent is untouched")
    }

    func test_clampsContentSizeWrittenAfterInstall() {
        let scrollView = makeScrollView()
        let lock = HorizontalOverflowLock(scrollView: scrollView)
        defer { _ = lock }

        // SwiftUI re-sets contentSize on every layout pass; the KVO hook
        // must clamp those later writes too, not just the install-time one.
        scrollView.contentSize = CGSize(width: 512, height: 2000)

        XCTAssertEqual(scrollView.contentSize.width, 320)
        XCTAssertEqual(scrollView.contentSize.height, 2000)
    }

    func test_resetsStrayHorizontalOffset() {
        let scrollView = makeScrollView()
        scrollView.contentSize = CGSize(width: 400, height: 1000)
        scrollView.contentOffset = CGPoint(x: 40, y: 250)

        let lock = HorizontalOverflowLock(scrollView: scrollView)
        defer { _ = lock }

        XCTAssertEqual(scrollView.contentOffset.x, 0,
                       "a mid-wiggle offset snaps back when the clamp lands")
        XCTAssertEqual(scrollView.contentOffset.y, 250,
                       "vertical position is preserved")
    }

    func test_leavesFittingContentAlone() {
        let scrollView = makeScrollView()
        let lock = HorizontalOverflowLock(scrollView: scrollView)
        defer { _ = lock }

        scrollView.contentSize = CGSize(width: 320, height: 1000)
        XCTAssertEqual(scrollView.contentSize, CGSize(width: 320, height: 1000))

        // Narrower-than-viewport content must not be grown to fit either.
        scrollView.contentSize = CGSize(width: 200, height: 500)
        XCTAssertEqual(scrollView.contentSize, CGSize(width: 200, height: 500))
    }

    func test_ignoresWritesBeforeLayout() {
        // Zero-width bounds means layout hasn't happened; clamping to 0
        // would zero the content. The lock must wait for a real viewport.
        let scrollView = UIScrollView(frame: .zero)
        let lock = HorizontalOverflowLock(scrollView: scrollView)
        defer { _ = lock }

        scrollView.contentSize = CGSize(width: 400, height: 1000)
        XCTAssertEqual(scrollView.contentSize.width, 400)
    }

    func test_overflowingDescendants_reportsWideViewsButNotNestedScrollerContent() {
        let scrollView = makeScrollView()
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 900))
        scrollView.addSubview(container)

        let wideLabel = UILabel(frame: CGRect(x: 0, y: 100, width: 500, height: 20))
        container.addSubview(wideLabel)

        // A nested horizontal scroller (code block / diff pane) is SUPPOSED
        // to hold wide content — its innards are not offenders.
        let innerScroller = UIScrollView(frame: CGRect(x: 0, y: 200, width: 300, height: 80))
        let innerWide = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 80))
        innerScroller.addSubview(innerWide)
        container.addSubview(innerScroller)

        let offenders = HorizontalOverflowLock.overflowingDescendants(
            of: scrollView, viewportWidth: 320)

        XCTAssertEqual(offenders.count, 1, "only the wide label is an offender: \(offenders)")
        XCTAssertTrue(offenders[0].contains("UILabel"),
                      "the report names the offending view's type: \(offenders)")
        XCTAssertTrue(offenders[0].contains("500"),
                      "the report carries the offending width: \(offenders)")
    }
}

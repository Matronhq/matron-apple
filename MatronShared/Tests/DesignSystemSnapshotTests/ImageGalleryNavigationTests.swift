import XCTest
import CoreGraphics
@testable import MatronDesignSystem

/// Pins the pure navigation rules behind the fullscreen viewer's
/// previous/next stepping (Mac ←/→, iOS horizontal swipe): index
/// stepping with hard ends, neighbour preloading, swipe classification
/// against the existing swipe-down-to-dismiss, and the "3 of 12" counter.
final class ImageGalleryNavigationTests: XCTestCase {

    // MARK: - Stepping

    func test_step_forwardAndBack_inRange() {
        XCTAssertEqual(ImageGalleryNavigation.step(2, by: 1, count: 5), 3)
        XCTAssertEqual(ImageGalleryNavigation.step(2, by: -1, count: 5), 1)
    }

    func test_step_pastEitherEnd_returnsNil() {
        // No wrap-around: the ends are hard stops.
        XCTAssertNil(ImageGalleryNavigation.step(4, by: 1, count: 5))
        XCTAssertNil(ImageGalleryNavigation.step(0, by: -1, count: 5))
    }

    func test_step_singleOrEmptyGallery_returnsNil() {
        XCTAssertNil(ImageGalleryNavigation.step(0, by: 1, count: 1))
        XCTAssertNil(ImageGalleryNavigation.step(0, by: -1, count: 1))
        XCTAssertNil(ImageGalleryNavigation.step(0, by: 1, count: 0))
    }

    // MARK: - Preload

    func test_preloadIndices_middle_bothNeighbours() {
        XCTAssertEqual(ImageGalleryNavigation.preloadIndices(around: 2, count: 5), [1, 3])
    }

    func test_preloadIndices_atEnds_onlyInRangeNeighbour() {
        XCTAssertEqual(ImageGalleryNavigation.preloadIndices(around: 0, count: 5), [1])
        XCTAssertEqual(ImageGalleryNavigation.preloadIndices(around: 4, count: 5), [3])
        XCTAssertEqual(ImageGalleryNavigation.preloadIndices(around: 0, count: 1), [])
    }

    // MARK: - Retained cache window

    func test_retainedIndices_windowAroundIndex() {
        // Resolved images are kept only near the current index so holding
        // an arrow key through a big gallery can't pin every bitmap.
        XCTAssertEqual(
            ImageGalleryNavigation.retainedIndices(around: 10, count: 50, radius: 3),
            Set([7, 8, 9, 10, 11, 12, 13])
        )
    }

    func test_retainedIndices_clampedAtEnds() {
        XCTAssertEqual(
            ImageGalleryNavigation.retainedIndices(around: 0, count: 5, radius: 3),
            Set([0, 1, 2, 3])
        )
        XCTAssertEqual(
            ImageGalleryNavigation.retainedIndices(around: 4, count: 5, radius: 3),
            Set([1, 2, 3, 4])
        )
    }

    // MARK: - Swipe classification (iOS)

    func test_swipe_leftPastThreshold_isNext() {
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: -120, height: 10), threshold: 60),
            .next
        )
    }

    func test_swipe_rightPastThreshold_isPrevious() {
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: 90, height: -5), threshold: 60),
            .previous
        )
    }

    func test_swipe_downPastThreshold_isDismiss() {
        // The existing swipe-down-to-dismiss keeps its meaning.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: 8, height: 130), threshold: 60),
            .dismiss
        )
    }

    func test_swipe_up_isNone() {
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: 0, height: -200), threshold: 60),
            .none
        )
    }

    func test_swipe_diagonal_dominantAxisWins() {
        // More horizontal than vertical → a page step, even though the
        // vertical travel alone would have cleared the threshold.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: -100, height: 70), threshold: 60),
            .next
        )
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: 70, height: 100), threshold: 60),
            .dismiss
        )
    }

    func test_swipe_underThreshold_isNone() {
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(translation: CGSize(width: -40, height: 0), threshold: 60),
            .none
        )
    }

    func test_swipe_shortFastFlick_pages() {
        // A thumb flick travels well under the threshold but is moving
        // fast when it lifts, so its predicted end clears it — the way
        // Photos pages.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: -60, height: 6),
                predictedEndTranslation: CGSize(width: -320, height: 20),
                threshold: 100),
            .next
        )
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: 45, height: -4),
                predictedEndTranslation: CGSize(width: 260, height: -10),
                threshold: 100),
            .previous
        )
    }

    func test_swipe_shortSlowDrag_isNone() {
        // Released almost at rest: the predicted end is where the finger
        // stopped, so a short drag still springs back.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: -60, height: 0),
                predictedEndTranslation: CGSize(width: -66, height: 0),
                threshold: 100),
            .none
        )
    }

    func test_swipe_tinyJitterWithVelocity_isNone() {
        // A few points of travel is a tap or a wobble, however fast.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: -12, height: 0),
                predictedEndTranslation: CGSize(width: -240, height: 0),
                threshold: 100),
            .none
        )
    }

    func test_swipe_flickReversedAtRelease_isNone() {
        // Dragged left, then flicked back right before lifting: the
        // momentum points the other way, so neither neighbour is meant.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: -60, height: 0),
                predictedEndTranslation: CGSize(width: 150, height: 0),
                threshold: 100),
            .none
        )
    }

    func test_swipe_shortFastDownFlick_doesNotDismiss() {
        // Dismiss keeps its distance rule: closing the viewer by accident
        // costs more than a missed page.
        XCTAssertEqual(
            ImageGalleryNavigation.swipeIntent(
                translation: CGSize(width: 4, height: 50),
                predictedEndTranslation: CGSize(width: 10, height: 400),
                threshold: 100),
            .none
        )
    }

    // MARK: - Counter

    func test_counterLabel_oneBased() {
        XCTAssertEqual(ImageGalleryNavigation.counterLabel(index: 2, count: 12), "3 of 12")
    }

    func test_counterLabel_hiddenForSingleImage() {
        XCTAssertNil(ImageGalleryNavigation.counterLabel(index: 0, count: 1))
        XCTAssertNil(ImageGalleryNavigation.counterLabel(index: 0, count: 0))
    }
}

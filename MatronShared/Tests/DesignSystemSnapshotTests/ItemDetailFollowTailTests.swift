import XCTest
@testable import MatronDesignSystem

/// Pins `ItemDetailView.shouldFollowTail` — the re-pin decision made when
/// the comment thread grows (Bugbot, PR #198). The load-gate is the point:
/// an unread item opens header-only, which is trivially "at the bottom",
/// and its opening refetch must not read as a new reply that drags the
/// viewport to the end.
final class ItemDetailFollowTailTests: XCTestCase {
    func test_followsTail_whenLoadedPlacedAtBottomAndGrew() {
        XCTAssertTrue(ItemDetailView.shouldFollowTail(threadLoaded: true, placed: true, atBottom: true, oldCount: 3, newCount: 4))
    }

    func test_openingLoadOfAnUnreadThread_doesNotFollow() {
        // Header-only thread, geometry would say at-bottom, comments arrive
        // from the opening refetch: stays where the reader is.
        XCTAssertFalse(ItemDetailView.shouldFollowTail(threadLoaded: false, placed: true, atBottom: true, oldCount: 0, newCount: 8))
    }

    func test_beforeInitialPlacement_doesNotFollow() {
        XCTAssertFalse(ItemDetailView.shouldFollowTail(threadLoaded: true, placed: false, atBottom: true, oldCount: 0, newCount: 1))
    }

    func test_readerAwayFromBottom_doesNotFollow() {
        XCTAssertFalse(ItemDetailView.shouldFollowTail(threadLoaded: true, placed: true, atBottom: false, oldCount: 3, newCount: 4))
    }

    func test_shrinkOrNoChange_doesNotFollow() {
        XCTAssertFalse(ItemDetailView.shouldFollowTail(threadLoaded: true, placed: true, atBottom: true, oldCount: 4, newCount: 3))
        XCTAssertFalse(ItemDetailView.shouldFollowTail(threadLoaded: true, placed: true, atBottom: true, oldCount: 4, newCount: 4))
    }
}

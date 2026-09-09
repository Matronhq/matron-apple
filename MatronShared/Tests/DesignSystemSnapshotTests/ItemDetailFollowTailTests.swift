import XCTest
@testable import MatronDesignSystem

/// Pins `ItemDetailView.shouldFollowTail` — the re-pin decision made when
/// the comment thread grows (Bugbot, PR #198). The load-gate is the point:
/// an unread item opens header-only, which is trivially "at the bottom",
/// and its opening refetch must not read as a new reply that drags the
/// viewport to the end.
final class ItemDetailFollowTailTests: XCTestCase {
    private func follows(loaded: Bool = true, startsAtBottom: Bool = false, placed: Bool = true, atBottom: Bool = true,
                         _ old: Int, _ new: Int) -> Bool {
        ItemDetailView.shouldFollowTail(threadLoaded: loaded, startsAtBottom: startsAtBottom, placed: placed,
                                        atBottom: atBottom, oldCount: old, newCount: new)
    }

    func test_followsTail_whenLoadedPlacedAtBottomAndGrew() {
        XCTAssertTrue(follows(3, 4))
    }

    func test_openingLoadOfAnUnreadThread_doesNotFollow() {
        // Header-only thread, geometry would say at-bottom, comments arrive
        // from the opening refetch: stays where the reader is.
        XCTAssertFalse(follows(loaded: false, 0, 8))
    }

    func test_openingLoadOfAReadToEndThread_doesFollow() {
        // The reader asked for the tail; the cached rows and then the
        // refetched ones must keep them pinned there through the load.
        XCTAssertTrue(follows(loaded: false, startsAtBottom: true, 0, 3))
        XCTAssertTrue(follows(loaded: false, startsAtBottom: true, 3, 8))
    }

    func test_beforeInitialPlacement_doesNotFollow() {
        XCTAssertFalse(follows(placed: false, 0, 1))
        XCTAssertFalse(follows(loaded: false, startsAtBottom: true, placed: false, 0, 1))
    }

    func test_readerAwayFromBottom_doesNotFollow() {
        XCTAssertFalse(follows(atBottom: false, 3, 4))
        XCTAssertFalse(follows(loaded: false, startsAtBottom: true, atBottom: false, 3, 4))
    }

    func test_shrinkOrNoChange_doesNotFollow() {
        XCTAssertFalse(follows(4, 3))
        XCTAssertFalse(follows(4, 4))
    }
}

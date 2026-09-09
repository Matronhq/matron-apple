import XCTest
@testable import MatronDesignSystem

/// Pins `ItemDetailView.shouldFollowTail` — the re-pin decision made when
/// the comment thread grows (Bugbot, PR #198). The load-gate is the point:
/// an unread item opens header-only, which is trivially "at the bottom",
/// and its opening refetch must not read as a new reply that drags the
/// viewport to the end — in whichever update the loaded count lands, and
/// even if a stale pre-refetch snapshot replays afterwards.
final class ItemDetailFollowTailTests: XCTestCase {
    private func follows(loaded: Int? = 3, startsAtBottom: Bool = false, placed: Bool = true, atBottom: Bool = true,
                         _ old: Int, _ new: Int) -> Bool {
        ItemDetailView.shouldFollowTail(loadedCount: loaded, startsAtBottom: startsAtBottom, placed: placed,
                                        atBottom: atBottom, oldCount: old, newCount: new)
    }

    func test_followsTail_whenLoadedPlacedAtBottomAndGrew() {
        XCTAssertTrue(follows(loaded: 3, 3, 4))
        XCTAssertTrue(follows(loaded: 3, 4, 5), "a pending row on top of the loaded thread still counts as loaded")
        XCTAssertTrue(follows(loaded: 0, 0, 1), "an empty loaded thread follows its first reply")
    }

    func test_openingLoadOfAnUnreadThread_doesNotFollow() {
        // Loaded count landing in the same update as the rows: the growth
        // starts below it, so it is the load, not a reply.
        XCTAssertFalse(follows(loaded: 8, 0, 8))
        // Landing in a later update: nothing is loaded yet.
        XCTAssertFalse(follows(loaded: nil, 0, 8))
        // A pending row of the reader's own during the load changes nothing.
        XCTAssertFalse(follows(loaded: 8, 1, 9))
    }

    func test_staleSnapshotReplayAfterTheLoad_doesNotFollow() {
        // 8 loaded → stale 3 (shrink) → fresh 8 again: neither leg re-pins.
        XCTAssertFalse(follows(loaded: 8, 8, 3))
        XCTAssertFalse(follows(loaded: 8, 3, 8))
    }

    func test_openingLoadOfAReadToEndThread_doesFollow() {
        // The reader asked for the tail; the cached rows and then the
        // refetched ones must keep them pinned there through the load.
        XCTAssertTrue(follows(loaded: nil, startsAtBottom: true, 0, 3))
        XCTAssertTrue(follows(loaded: 8, startsAtBottom: true, 3, 8))
    }

    func test_beforeInitialPlacement_doesNotFollow() {
        XCTAssertFalse(follows(placed: false, 3, 4))
        XCTAssertFalse(follows(loaded: nil, startsAtBottom: true, placed: false, 0, 1))
    }

    func test_readerAwayFromBottom_doesNotFollow() {
        XCTAssertFalse(follows(atBottom: false, 3, 4))
        XCTAssertFalse(follows(loaded: nil, startsAtBottom: true, atBottom: false, 3, 4))
    }

    func test_shrinkOrNoChange_doesNotFollow() {
        XCTAssertFalse(follows(4, 3))
        XCTAssertFalse(follows(4, 4))
    }
}

final class ItemDetailJumpToBottomTests: XCTestCase {
    func testShownOnlyWhenPlacedScrollableAndAwayFromTheBottom() {
        XCTAssertTrue(ItemDetailView.showsJumpToBottom(placed: true, scrollable: true, atBottom: false))
    }

    func testHiddenBeforeInitialPlacement() {
        XCTAssertFalse(ItemDetailView.showsJumpToBottom(placed: false, scrollable: true, atBottom: false))
    }

    func testHiddenWhenTheThreadFitsTheViewport() {
        // A short thread has nowhere to jump to — and before the first
        // geometry callback `scrollable` is false, so a freshly opened
        // item never flashes the button.
        XCTAssertFalse(ItemDetailView.showsJumpToBottom(placed: true, scrollable: false, atBottom: false))
    }

    func testHiddenAtTheBottom() {
        XCTAssertFalse(ItemDetailView.showsJumpToBottom(placed: true, scrollable: true, atBottom: true))
    }
}

final class ItemDetailResolveLabelTests: XCTestCase {
    func testLabelNamesThePrimaryResolution() {
        XCTAssertEqual(ItemDetailView.resolveLabel(for: [.done, .cancelled]), "Mark done")
        XCTAssertEqual(ItemDetailView.resolveLabel(for: [.answered, .cancelled]), "Mark answered")
        XCTAssertEqual(ItemDetailView.resolveLabel(for: [.reversed, .decided, .cancelled]), "Reverse")
    }

    func testAnUnansweredQuestionOnlyOffersDismissal() {
        XCTAssertEqual(ItemDetailView.resolveLabel(for: [.cancelled]), "Dismiss")
    }
}

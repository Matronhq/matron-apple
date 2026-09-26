import XCTest
import UIKit
import MatronChat
import MatronViewModels
@testable import Matron

/// Spec §2: opens at the bottom; stays pinned through streaming; content
/// never moves under a reader; own send returns to the tail; the activity
/// indicator is a footer outside the anchor space.
@MainActor
final class ChatTimelineControllerTests: XCTestCase {
    func test_opensAtTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        let last = IndexPath(item: h.controller.appliedRowIDs.count - 1, section: 0)
        XCTAssertTrue(h.collectionView.indexPathsForVisibleItems.contains(last))
        XCTAssertTrue(h.bridge.isFollowingTail)
    }

    func test_streamingReplyStaysPinned() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(40)
        try await h.start(with: items)
        var body = "Streaming"
        items.append(TimelineFixtures.streaming("r1", body: body))
        for step in 0..<5 {
            body += " step \(step) " + String(repeating: "growing words ", count: 12)
            items[items.count - 1] = TimelineFixtures.streaming("r1", body: body)
            try await h.emit(items)
            XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5, "step \(step)")
        }
    }

    func test_newMessageWhileReadingHistoryDoesNotMoveContent() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        h.drag(to: 400)
        let anchor = h.controller.scrollModel.topAnchor()
        items.append(TimelineFixtures.text(61))
        try await h.emit(items)
        XCTAssertEqual(h.collectionView.contentOffset.y, 400, accuracy: 0.5)
        XCTAssertEqual(h.controller.scrollModel.topAnchor(), anchor)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_ownSendReturnsToTheTail() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        h.drag(to: 300)
        items.append(TimelineFixtures.text(61, own: true))
        try await h.emit(items)
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    func test_activityFooterPinsWhileFollowing_andIsNotARow() async throws {
        let h = TimelineHarness()
        let items = TimelineFixtures.conversation(30)
        try await h.start(with: items)
        try await h.emit(items + [TimelineFixtures.activity("Thinking…")])
        XCTAssertGreaterThan(h.controller.scrollModel.footerHeight, 0)
        XCTAssertFalse(h.controller.appliedRowIDs.contains("activity"))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNotNil(h.collectionView.supplementaryView(forElementKind: TimelineLayout.footerKind,
                                                          at: TimelineLayout.footerIndexPath))
    }

    /// The turn ends: the footer's space goes and the tail stays pinned.
    func test_activityFooterClearsWhenTheTurnEnds() async throws {
        let h = TimelineHarness()
        let items = TimelineFixtures.conversation(30)
        try await h.start(with: items + [TimelineFixtures.activity("Thinking…")])
        XCTAssertGreaterThan(h.controller.scrollModel.footerHeight, 0)
        try await h.emit(items)
        XCTAssertNil(h.viewModel.activityLabel)
        XCTAssertEqual(h.controller.scrollModel.footerHeight, 0)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    func test_streamingRowRetiringBelowTheViewportDoesNotMoveTheReader() async throws {
        let h = TimelineHarness()
        let body = "Final answer. " + String(repeating: "Detail. ", count: 40)
        let history = TimelineFixtures.conversation(60)
        try await h.start(with: history + [TimelineFixtures.streaming("r1", body: body)])
        h.drag(to: 300)
        let anchor = h.controller.scrollModel.topAnchor()
        try await h.emit(history + [TimelineFixtures.text(61, body: body)])
        XCTAssertEqual(h.collectionView.contentOffset.y, 300, accuracy: 0.5)
        XCTAssertEqual(h.controller.scrollModel.topAnchor(), anchor)
    }

    func test_duplicateItemIDsRenderOnce() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(20) + [TimelineFixtures.text(20)])
        XCTAssertEqual(h.controller.appliedRowIDs.filter { $0 == "20" }.count, 1)
    }

    /// Carry-over: every `scrollViewDidScroll` (drag AND deceleration)
    /// reaches the model — anchor capture reads the model's offset.
    func test_userScrollOffsetsReachTheModel() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.controller.scrollViewWillBeginDragging(h.collectionView)
        h.collectionView.contentOffset = CGPoint(x: 0, y: 420)
        XCTAssertEqual(h.controller.scrollModel.contentOffsetY, 420)
        // Momentum, after the finger lifted.
        h.controller.scrollViewDidEndDragging(h.collectionView, willDecelerate: true)
        h.collectionView.contentOffset = CGPoint(x: 0, y: 380)
        XCTAssertEqual(h.controller.scrollModel.contentOffsetY, 380)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    /// Review fix: the first sync after a precompute lands always applies,
    /// even if the cache already lost the batch (eviction) — otherwise
    /// schedule → land → sync → schedule loops with nothing on screen.
    func test_precomputeEvictedBeforeApply_stillApplies() async throws {
        let h = TimelineHarness(cache: TimelineMeasureCache(countLimit: 1))
        try await h.start(with: TimelineFixtures.conversation(60))
        XCTAssertEqual(h.controller.appliedRowIDs.count, h.viewModel.windowedRows.count)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertFalse(h.collectionView.indexPathsForVisibleItems.isEmpty)
    }

    /// Review fix: a status-bar tap scrolls to the top without a drag; it
    /// must still release follow-tail, or the next streaming apply snaps
    /// the reader back to the bottom.
    func test_statusBarScrollToTopReleasesFollowTail() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        XCTAssertTrue(h.controller.scrollViewShouldScrollToTop(h.collectionView))
        XCTAssertFalse(h.bridge.isFollowingTail)
        XCTAssertFalse(h.controller.scrollModel.isFollowingTail)
        h.collectionView.contentOffset = .zero // the system's scroll-to-top animation
        h.controller.scrollViewDidScrollToTop(h.collectionView)
        items.append(TimelineFixtures.streaming("r1", body: "Streaming reply"))
        try await h.emit(items)
        XCTAssertEqual(h.collectionView.contentOffset.y, 0, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    /// Review optional: the same id switching text → hosted while reading
    /// history reloads (a reconfigure would trap on the cell-class change)
    /// and leaves the reader where they were.
    func test_rowSwitchingKindWhileReading_keepsThePosition() async throws {
        let h = TimelineHarness()
        var items = TimelineFixtures.conversation(60)
        try await h.start(with: items)
        h.drag(to: 400)
        let anchor = h.controller.scrollModel.topAnchor()
        let index = items.count - 3
        let old = items[index]
        items[index] = TimelineItem(id: old.id, sender: old.sender, timestamp: old.timestamp,
                                    kind: .file(url: nil, filename: "notes.txt", caption: nil, sizeBytes: 10, expired: false),
                                    isOwn: false)
        try await h.emit(items)
        XCTAssertEqual(h.collectionView.contentOffset.y, 400, accuracy: 0.5)
        XCTAssertEqual(h.controller.scrollModel.topAnchor(), anchor)
        let row = try XCTUnwrap(h.controller.scrollModel.index(of: old.id))
        h.collectionView.contentOffset = CGPoint(x: 0, y: h.controller.scrollModel.rowMinY(at: row) - 100)
        h.collectionView.layoutIfNeeded()
        XCTAssertTrue(h.collectionView.cellForItem(at: IndexPath(item: row, section: 0)) is HostedRowCell)
    }

    /// F10: the bottom hug survives a viewport resize (keyboard up/down) —
    /// in the model AND in the frames UIKit actually lays out.
    func test_shortConversationHugsTheComposer() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(2))
        assertHugsTheBottom(h)

        // The composer riding the keyboard shrinks the timeline's frame
        // (ChatKeyboardAvoidance) — the window and its safe area stay put.
        for height: CGFloat in [420, 700] {
            h.controller.view.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: height))
            h.controller.view.layoutIfNeeded()
            XCTAssertEqual(h.collectionView.bounds.height, height)
            assertHugsTheBottom(h, "viewport \(height)")
        }
    }

    private func assertHugsTheBottom(_ h: TimelineHarness, _ message: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        let model = h.controller.scrollModel
        let last = model.rows.count - 1
        let viewport = h.collectionView.bounds.height
        XCTAssertEqual(model.rowMinY(at: last) + model.rows[last].height + 16, viewport,
                       accuracy: 0.5, message, file: file, line: line)
        let frame = h.collectionView.layoutAttributesForItem(at: IndexPath(item: last, section: 0))?.frame
        XCTAssertEqual(frame?.maxY ?? 0, viewport - 16, accuracy: 0.5, message, file: file, line: line)
        XCTAssertEqual(h.collectionView.contentOffset.y, 0, message, file: file, line: line)
    }
    // MARK: PR #243 fixes

    /// CI fix: `isolated deinit` needs an experimental flag, so the plain
    /// `deinit` must still take a PAUSED link off the run loop when the
    /// coalescer is dropped without `invalidate()` — a paused link never
    /// ticks, so the target's own "owner gone" check can't catch it.
    func test_coalescerReleasedWithoutInvalidate_takesItsLinkOffTheRunLoop() async throws {
        var fired = 0
        var coalescer: FrameCoalescer? = FrameCoalescer { fired += 1 }
        coalescer?.request()
        weak var link = coalescer?.displayLinkForTesting
        XCTAssertNotNil(link)
        try await waitUntil { fired == 1 }
        XCTAssertEqual(link?.isPaused, true, "precondition: fired once, then paused itself")
        coalescer = nil
        try await waitUntil { link == nil }
        XCTAssertEqual(fired, 1)
    }
}

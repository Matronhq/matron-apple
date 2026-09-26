import XCTest
import UIKit
@testable import Matron

/// Spec §2 Pagination: within 1.5 screens of the top, reveal older rows;
/// the prepend keeps the anchor exactly (no pins, no retries).
@MainActor
final class TimelinePaginationTests: XCTestCase {
    func test_scrollingNearTheTopRevealsOlderRowsWithoutMovingContent() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(300))
        let before = h.controller.appliedRowIDs.count
        h.drag(to: 200)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        let y = try XCTUnwrap(h.onScreenY(anchor.rowID))
        try await waitUntil(timeout: 5) { h.controller.appliedRowIDs.count > before && !h.controller.hasPendingWork }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(anchor.rowID)), y, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_exhaustedHistory_doesNotRetrigger() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(30))
        h.drag(to: 10)
        try await waitUntil { h.controller.extendRequestCount == 1 && !h.viewModel.isExtendingWindow
            && !h.viewModel.isPaginatingBackward }
        try await Task.sleep(nanoseconds: 100_000_000)
        for y in [4.0, 12.0, 6.0, 20.0] as [CGFloat] { h.collectionView.contentOffset = CGPoint(x: 0, y: y) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.controller.extendRequestCount, 1, "no new rows came back — don't spin")
    }

    func test_detachedWindow_revealsNewerRowsNearTheBottom_keepingTheAnchor() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(600))
        h.viewModel.ensureWindowContains("100")
        try await h.settle()
        // `ensureWindowContains` holds `isExtendingWindow` for 150ms, which
        // (correctly) blocks reveals; start reading after it drops.
        try await waitUntil { !h.viewModel.isExtendingWindow }
        XCTAssertFalse(h.viewModel.windowContainsTail)
        let anchorBefore = h.viewModel.windowTailAnchorID
        h.drag(to: h.maxOffset - 40)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        let y = try XCTUnwrap(h.onScreenY(anchor.rowID))
        try await waitUntil(timeout: 5) { h.viewModel.windowTailAnchorID != anchorBefore }
        try await h.settle()
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(anchor.rowID)), y, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail, "a detached window's bottom never re-arms follow")
    }
}

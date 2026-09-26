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

    /// Fix round 1 [Important]: `extendInFlight` / `isExtendingWindow`
    /// clear a fixed 150ms after the model change, but a big batch's
    /// precompute (and the apply that follows it) can outlive that hold —
    /// a scroll frame landing in the gap used to see every guard clear and
    /// re-fire. `hasPendingWork` (precompute in flight, or a sync already
    /// coalesced) now covers exactly that gap.
    func test_pagingDoesNotRefireWhileThePrecomputeIsPending() async throws {
        let h = TimelineHarness(precomputeDelayNanosecondsForTesting: 400_000_000)
        try await h.start(with: TimelineFixtures.conversation(300))
        h.drag(to: 200)
        try await waitUntil { h.controller.extendRequestCount == 1 }
        // The view model's own 150ms hold clears well before the (test-held)
        // 400ms precompute lands — keep nudging the scroll position through
        // that gap and make sure nothing re-fires.
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(h.controller.hasPendingWork, "expected the precompute to still be in flight")
        for y in [190.0, 210.0, 195.0, 205.0] as [CGFloat] { h.collectionView.contentOffset = CGPoint(x: 0, y: y) }
        XCTAssertEqual(h.controller.extendRequestCount, 1, "no re-fire while the batch is still landing")
        try await h.settle()
    }

    /// Fix round 1 [Important], detached-window twin: `revealNewerHistory`
    /// has the same flat 150ms hold as `extendHistoryWindow`, so the same
    /// gap exists at the bottom of a detached window.
    func test_detachedWindowRevealDoesNotRefireWhileThePrecomputeIsPending() async throws {
        let h = TimelineHarness(precomputeDelayNanosecondsForTesting: 400_000_000)
        try await h.start(with: TimelineFixtures.conversation(900))
        h.viewModel.ensureWindowContains("100")
        try await h.settle()
        try await waitUntil { !h.viewModel.isExtendingWindow }
        XCTAssertFalse(h.viewModel.windowContainsTail)
        let anchorBefore = h.viewModel.windowTailAnchorID
        h.drag(to: h.maxOffset - 40)
        try await waitUntil { h.viewModel.windowTailAnchorID != anchorBefore }
        let anchorAfterFirstSlide = h.viewModel.windowTailAnchorID
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertTrue(h.controller.hasPendingWork, "expected the precompute to still be in flight")
        for y in [h.maxOffset - 60, h.maxOffset - 20, h.maxOffset - 50] as [CGFloat] {
            h.collectionView.contentOffset = CGPoint(x: 0, y: y)
        }
        XCTAssertEqual(h.viewModel.windowTailAnchorID, anchorAfterFirstSlide,
                       "no second slide while the batch is still landing")
        XCTAssertFalse(h.bridge.isFollowingTail)
        try await h.settle()
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

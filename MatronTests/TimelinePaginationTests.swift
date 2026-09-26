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

    /// Review fix round 2: this used to pass on `endUserScroll()` re-arming
    /// follow-tail after the initial drag settles, never actually
    /// exercising `exhaustedHeadID` (repeated pokes were no-ops with
    /// follow back ON, regardless of the latch). Also, `reachedHistoryStart`
    /// only trips after TWO consecutive no-growth `paginateBackward` calls
    /// (one flaky round must not lock scroll-up for the session) — so the
    /// ORIGINAL single drag here could never have latched anything even
    /// with the mechanism working. Primes `reachedHistoryStart` directly on
    /// the view model (off the controller — `waitUntil`'s `!isExtendingWindow
    /// && !isPaginatingBackward` is trivially true before the async extend
    /// Task has even started, so polling for it here races), then proves
    /// the controller's own single, now-genuinely-exhausted call latches
    /// and follow stays off.
    func test_exhaustedHistory_doesNotRetrigger() async throws {
        let h = TimelineHarness(attach: false)
        h.service.emit(TimelineFixtures.conversation(30))
        _ = await h.viewModel.start()
        try await waitUntil { h.viewModel.items.count == 30 }
        // Nothing local to grow into, ever, for a 30-row conversation —
        // two real no-growth network rounds prime `reachedHistoryStart`.
        await h.viewModel.extendHistoryWindow()
        await h.viewModel.extendHistoryWindow()
        XCTAssertTrue(h.viewModel.reachedHistoryStart, "primed")

        h.attach()
        try await h.settle()
        h.drag(to: 10)
        try await Task.sleep(nanoseconds: 50_000_000) // let the extend Task actually start
        try await waitUntil(timeout: 5) { !h.viewModel.isExtendingWindow && !h.viewModel.isPaginatingBackward }
        XCTAssertFalse(h.bridge.isFollowingTail, "must still be reading history, not re-armed")
        XCTAssertNotNil(h.controller.exhaustedHeadID, "the latch, not follow-tail, must be what holds this")
        for y in [4.0, 12.0, 6.0, 20.0] as [CGFloat] { h.collectionView.contentOffset = CGPoint(x: 0, y: y) }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.controller.extendRequestCount, 1, "no new rows came back — don't spin")
    }

    /// Fix round 2 [Important]: the latch requires BOTH the view model's
    /// own `reachedHistoryStart` AND "this extend made no progress"
    /// (`newHead == head`). `reachedHistoryStart` stays true for the life
    /// of the view model, so gating on it alone latched the PRE-call head
    /// of a later, perfectly successful local grow too — which could then
    /// block a legitimate reveal that later walks back onto that same
    /// head. Primes `reachedHistoryStart` directly on the view model (off
    /// the controller entirely, per the reviewer's suggested test hook),
    /// then proves a genuinely exhausted call still latches, and a later
    /// successful one — despite the stale flag — does not.
    func test_reachedHistoryStartAloneDoesNotLatchASuccessfulExtend() async throws {
        let h = TimelineHarness(attach: false)
        h.service.emit(TimelineFixtures.conversation(300))
        _ = await h.viewModel.start()
        try await waitUntil { h.viewModel.items.count == 300 }
        // Two local grows exhaust the local rows into the window
        // (120→240→everything local), then two real no-growth network
        // rounds flip `reachedHistoryStart` — the same threshold
        // `paginateBackward` itself uses. All off the controller:
        // `exhaustedHeadID` never sees any of this.
        for _ in 0..<4 { await h.viewModel.extendHistoryWindow() }
        let windowSizeAfterPriming = h.viewModel.visibleWindowSize
        XCTAssertEqual(windowSizeAfterPriming, h.viewModel.rows.count, "window now covers every local row")
        XCTAssertTrue(h.viewModel.reachedHistoryStart, "primed")

        h.attach()
        try await h.settle()
        h.drag(to: 10)
        try await Task.sleep(nanoseconds: 50_000_000) // let the extend Task actually start
        try await waitUntil(timeout: 5) { !h.viewModel.isExtendingWindow && !h.viewModel.isPaginatingBackward }
        // Genuinely nothing local or remote to reveal from here — this one
        // SHOULD latch.
        XCTAssertEqual(h.controller.extendRequestCount, 1)
        XCTAssertEqual(h.controller.exhaustedHeadID, "1")

        // More history becomes available some other way (a real paginate
        // elsewhere, a mirror refresh) — `reachedHistoryStart` is still
        // (stalely) true, but there is real local room to grow into again.
        h.service.emit(TimelineFixtures.conversation(500))
        try await waitUntil { h.viewModel.items.count == 500 }
        try await h.settle()
        h.drag(to: 10)
        try await Task.sleep(nanoseconds: 50_000_000) // let the extend Task actually start
        try await waitUntil(timeout: 5) { !h.viewModel.isExtendingWindow && !h.viewModel.isPaginatingBackward }
        XCTAssertEqual(h.controller.extendRequestCount, 2)
        XCTAssertGreaterThan(h.viewModel.visibleWindowSize, windowSizeAfterPriming,
                             "the extend actually grew the window — real progress")
        XCTAssertNil(h.controller.exhaustedHeadID, "a successful extend must not latch, even with a stale reachedHistoryStart")
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

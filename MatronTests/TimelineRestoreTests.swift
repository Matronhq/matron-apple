import XCTest
import UIKit
import MatronViewModels
@testable import Matron

/// Spec §2 Scroll restoration.
@MainActor
final class TimelineRestoreTests: XCTestCase {
    func test_leavingAndReopening_restoresTheExactPosition() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(100))
        h.drag(to: 1500)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        h.bridge.storeScrollPosition()
        h.remount()
        try await h.settle()
        try await waitUntil { !h.controller.hasPendingRestore }
        let restored = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        XCTAssertEqual(restored.rowID, anchor.rowID)
        XCTAssertEqual(restored.offsetInRow, anchor.offsetInRow, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_swiftUIPathEntry_restoresBottomAligned() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60")
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        try await waitUntil { !h.controller.hasPendingRestore }
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "60"))
        let bottom = h.controller.scrollModel.rowMinY(at: index) + h.controller.scrollModel.rows[index].height
            - h.collectionView.contentOffset.y
        XCTAssertEqual(bottom, h.collectionView.bounds.height, accuracy: 0.5)
    }

    func test_goneRow_fallsBackToTheTail_andForgets() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "9999", offsetInRow: 10)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(40))
        try await waitUntil { !h.controller.hasPendingRestore }
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }

    /// Review F3: no `jumpToBottom()` here — that forgets on its own, so the
    /// test never reached the store-versus-forget decision. The stale entry
    /// is written after mount (a pre-mount entry would be restored, which
    /// releases follow-tail), so the controller is genuinely following.
    func test_leavingWhileFollowing_forgetsTheMemory() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(40))
        XCTAssertTrue(h.bridge.isFollowingTail)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "3")
        h.bridge.storeScrollPosition()
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }

    // MARK: Review rulings

    /// A deep entry outside the default 120-row window widens once, then lands.
    func test_targetOutsideTheWindow_widensThenLandsExactly() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "30", offsetInRow: 12)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(200))
        try await waitUntil(timeout: 5) { !h.controller.hasPendingRestore && !h.controller.hasPendingWork }
        let restored = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        XCTAssertEqual(restored.rowID, "30")
        XCTAssertEqual(restored.offsetInRow, 12, accuracy: 0.5)
    }

    /// F5: the jump-to-bottom button cancels a pending restore.
    func test_jumpToBottom_cancelsAPendingRestore() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60", offsetInRow: 5)
        h.attach()
        XCTAssertTrue(h.controller.hasPendingRestore, "no rows yet: the restore waits")
        h.bridge.jumpToBottom()
        XCTAssertFalse(h.controller.hasPendingRestore)
        try await h.start(with: TimelineFixtures.conversation(100))
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    /// F5: a user drag cancels a pending restore — the user has taken over.
    func test_userDrag_cancelsAPendingRestore() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60", offsetInRow: 5)
        h.attach()
        XCTAssertTrue(h.controller.hasPendingRestore)
        h.controller.scrollViewWillBeginDragging(h.collectionView)
        XCTAssertFalse(h.controller.hasPendingRestore)
        try await h.start(with: TimelineFixtures.conversation(100))
        XCTAssertNotEqual(h.controller.scrollModel.topAnchor()?.rowID, "60", "the restore never landed")
    }

    /// F5: a pending focus jump wins over a pending restore.
    func test_pendingFocus_cancelsTheRestore_andTheJumpLands() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60", offsetInRow: 5)
        h.service.emit(TimelineFixtures.conversation(200))
        _ = await h.viewModel.start()
        await h.viewModel.focus(seq: 150)
        h.attach()
        try await waitUntil(timeout: 5) {
            h.viewModel.pendingFocusID == nil && !h.controller.hasPendingWork && !h.controller.hasPendingRestore
        }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("150")), 0, accuracy: 0.5)
    }

    /// Task 10 carry-over: an offset past the row's height (the row got
    /// shorter since) is clamped to the row — the viewport top sits at the
    /// row's bottom edge, not wherever the stale offset would have thrown it.
    func test_offsetBeyondTheRow_isClampedToTheRowHeight() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "20", offsetInRow: 50_000)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        try await waitUntil { !h.controller.hasPendingRestore }
        let height = try XCTUnwrap(h.controller.scrollModel.height(of: "20"))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("20")), -height, accuracy: 0.5)
    }

    /// Task 10 carry-over: nothing restores against a zero-height viewport
    /// (a bottom-aligned restore would compute against 0); it lands once
    /// the real height arrives.
    func test_restoreWaitsForTheViewportHeight() async throws {
        let h = TimelineHarness(size: CGSize(width: 393, height: 0), attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60")
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        XCTAssertTrue(h.controller.hasPendingRestore, "no viewport height yet")
        h.window.frame = CGRect(x: 0, y: 0, width: 393, height: 700)
        h.controller.view.frame = h.window.bounds
        h.controller.view.layoutIfNeeded()
        try await waitUntil { !h.controller.hasPendingRestore }
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "60"))
        let bottom = h.controller.scrollModel.rowMinY(at: index) + h.controller.scrollModel.rows[index].height
            - h.collectionView.contentOffset.y
        XCTAssertEqual(bottom, 700, accuracy: 0.5)
    }

    /// Task 22 carry-over: a restore landing near the top must not read as
    /// the user paging — no older-history request off the landing apply.
    func test_restoreLandingNearTheTop_doesNotPage() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "2", offsetInRow: 0)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        try await waitUntil { !h.controller.hasPendingRestore }
        XCTAssertTrue(h.controller.scrollModel.isNearTop)
        try await h.settle()
        XCTAssertEqual(h.controller.extendRequestCount, 0)
    }

    /// F6: the representable's dismantle stores through the controller, so
    /// a position is remembered even when `onDisappear`'s weak bridge call
    /// finds the controller already gone.
    func test_tearDown_storesThePosition() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(100))
        h.drag(to: 1500)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        h.controller.tearDown()
        let stored = try XCTUnwrap(ChatScrollPositionMemory.retrievePosition(roomID: h.viewModel.roomID))
        XCTAssertEqual(stored.itemID, anchor.rowID)
        XCTAssertEqual(try XCTUnwrap(stored.offsetInRow), Double(anchor.offsetInRow), accuracy: 0.5)
    }

    /// F6: `onDisappear` stores first and then shrinks the window; a later
    /// dismantle must not overwrite that entry with the post-shrink position.
    func test_tearDownAfterAnExplicitStore_keepsTheExplicitEntry() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        h.viewModel.ensureWindowContains("30")
        try await h.settle()
        h.drag(to: 1500)
        let anchor = try XCTUnwrap(h.controller.scrollModel.topAnchor())
        h.bridge.storeScrollPosition()
        h.viewModel.resetHistoryWindow()
        try await h.settle()
        XCTAssertNil(h.controller.scrollModel.index(of: anchor.rowID), "precondition: the shrink dropped the row")
        h.controller.tearDown()
        XCTAssertEqual(ChatScrollPositionMemory.retrievePosition(roomID: h.viewModel.roomID)?.itemID, anchor.rowID)
    }
}

import XCTest
import UIKit
import MatronViewModels
@testable import Matron

/// Spec §2 Keyboard + Review Focus 4: resizes and re-measures never move
/// the message the reader is looking at.
@MainActor
final class TimelineResizeTests: XCTestCase {
    private func resize(_ h: TimelineHarness, to size: CGSize) {
        h.window.frame = CGRect(origin: .zero, size: size)
        h.window.layoutIfNeeded()
        h.controller.view.layoutIfNeeded()
    }

    func test_keyboardResize_whilePinned_staysAtTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        resize(h, to: CGSize(width: 393, height: 400))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        resize(h, to: CGSize(width: 393, height: 700))
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
    }

    func test_keyboardResize_whileReading_keepsTheBottomRowFixed() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let bottom = try XCTUnwrap(h.controller.scrollModel.bottomAnchor())
        let before = try XCTUnwrap(h.onScreenY(bottom.rowID))
        resize(h, to: CGSize(width: 393, height: 400))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(bottom.rowID)), before - 300, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    /// Controller ruling (Task 28 fix round 1): a jump that lands while the
    /// keyboard is up keeps the landed row at the top when the keyboard
    /// hides (viewport grows 284 pt) — the Find-in-chat submit path.
    func test_keyboardHidesAfterAJump_theJumpedRowStaysAtTheTop() async throws {
        let h = TimelineHarness(size: CGSize(width: 393, height: 416))
        try await h.start(with: TimelineFixtures.conversation(200))
        await h.viewModel.focus(seq: 150)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("150")), 0, accuracy: 0.5)
        resize(h, to: CGSize(width: 393, height: 700))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("150")), 0, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    /// The landing's top hold ends at the user's next scroll: after a drag,
    /// a resize keeps the bottom-visible row fixed again (spec §2 Keyboard).
    func test_afterAUserDrag_aResizeKeepsTheBottomRowFixedAgain() async throws {
        let h = TimelineHarness(size: CGSize(width: 393, height: 416))
        try await h.start(with: TimelineFixtures.conversation(200))
        await h.viewModel.focus(seq: 150)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        h.drag(to: h.collectionView.contentOffset.y - 200)
        let bottom = try XCTUnwrap(h.controller.scrollModel.bottomAnchor())
        let before = try XCTUnwrap(h.onScreenY(bottom.rowID))
        resize(h, to: CGSize(width: 393, height: 700))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(bottom.rowID)), before + 284, accuracy: 0.5)
    }

    /// Fix round 2 ruling: only a JUMP landing holds the top. A restored
    /// position then a composer tap (keyboard shows, viewport shrinks 284 pt)
    /// keeps the bottom row the reader was on fixed (spec §2 Keyboard).
    func test_keyboardShowsAfterARestore_keepsTheBottomRowFixed() async throws {
        let h = TimelineHarness(attach: false)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "60", offsetInRow: 0)
        h.attach()
        try await h.start(with: TimelineFixtures.conversation(100))
        try await waitUntil { !h.controller.hasPendingRestore }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("60")), 0, accuracy: 0.5, "restore landed")
        let bottom = try XCTUnwrap(h.controller.scrollModel.bottomAnchor())
        let before = try XCTUnwrap(h.onScreenY(bottom.rowID))
        resize(h, to: CGSize(width: 393, height: 416))
        XCTAssertEqual(try XCTUnwrap(h.onScreenY(bottom.rowID)), before - 284, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }

    func test_widthChangeWhileReading_keepsTheTopMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let top = try XCTUnwrap(h.controller.scrollModel.topAnchor()).rowID
        resize(h, to: CGSize(width: 700, height: 700))
        try await h.settle()
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, top)
    }

    /// CI (PR #243): a reader deep in a row that the wider layout makes
    /// SHORTER than their offset into it. Clamping the offset to the new
    /// height parked the viewport exactly on that row's bottom edge — fully
    /// scrolled off — so the NEXT message became the top one. The row stays
    /// at the top, still on screen, at the same relative depth.
    func test_widthChange_deepInARowThatShrinks_keepsThatRowAtTheTop() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        let model = { h.controller.scrollModel }
        let index = try XCTUnwrap(model().index(of: "13"))
        let heightBefore = try XCTUnwrap(model().height(of: "13"))
        let depth = heightBefore - 4
        h.drag(to: model().rowMinY(at: index) + depth)
        XCTAssertEqual(model().topAnchor()?.rowID, "13")
        resize(h, to: CGSize(width: 700, height: 700))
        try await h.settle()
        let heightAfter = try XCTUnwrap(model().height(of: "13"))
        XCTAssertLessThan(heightAfter, depth, "precondition: the row shrinks below the reader's offset")
        XCTAssertEqual(model().topAnchor()?.rowID, "13")
        let y = try XCTUnwrap(h.onScreenY("13"))
        XCTAssertEqual(-y / heightAfter, depth / heightBefore, accuracy: 0.02, "same relative depth into the row")
    }

    func test_dynamicTypeChangeWhileReading_keepsTheTopMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let top = try XCTUnwrap(h.controller.scrollModel.topAnchor()).rowID
        let heightBefore = try XCTUnwrap(h.controller.scrollModel.height(of: "30"))
        h.controller.traitOverrides.preferredContentSizeCategory = .accessibilityLarge
        try await waitUntil(timeout: 5) { (h.controller.scrollModel.height(of: "30") ?? 0) > heightBefore }
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, top)
    }

    func test_collectionView_isConfiguredForTheGuideComposer() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        XCTAssertEqual(h.collectionView.keyboardDismissMode, .interactive)
        XCTAssertEqual(h.collectionView.contentInsetAdjustmentBehavior, .never)
    }

    /// MUST 2 (Review Focus 4): rotation changes width AND height in one
    /// layout pass. The message at the top stays at the top, at the same
    /// on-screen Y — not the bottom-visible row.
    func test_rotationWhileReading_keepsTheTopMessageInPlace() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "30"))
        h.drag(to: h.controller.scrollModel.rowMinY(at: index) + 10)
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, "30")
        let before = try XCTUnwrap(h.onScreenY("30"))
        resize(h, to: CGSize(width: 852, height: 393))
        try await h.settle()
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, "30")
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("30")), before, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
    }
}

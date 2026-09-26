import XCTest
import UIKit
import MatronViewModels
@testable import Matron

/// Spec §2 Jumps: pendingFocusID → ensureWindowContains → apply → exact
/// frame → stop deceleration → row top at the viewport top → flash.
@MainActor
final class TimelineJumpTests: XCTestCase {
    func test_focusLandsTheRowAtTheTop_andFlashesIt() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        await h.viewModel.focus(seq: 150)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("150")), 0, accuracy: 0.5)
        XCTAssertFalse(h.bridge.isFollowingTail)
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "150"))
        let cell = try XCTUnwrap(h.collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
        XCTAssertTrue(cell.subviews.contains { $0.accessibilityIdentifier == "chat.timeline.flash" })
    }

    /// Bugbot "Jump flash survives cell reuse": a second jump onto the same
    /// cell replaces the flash, and a recycled cell never carries one over.
    func test_jumpFlash_isReplacedNotStacked_andClearedOnReuse() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        await h.viewModel.focus(seq: 150)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        let index = try XCTUnwrap(h.controller.scrollModel.index(of: "150"))
        let cell = try XCTUnwrap(h.collectionView.cellForItem(at: IndexPath(item: index, section: 0)))
        let flashes = { cell.subviews.filter { $0.accessibilityIdentifier == "chat.timeline.flash" } }
        XCTAssertEqual(flashes().count, 1)
        h.controller.flashRow("150")
        XCTAssertEqual(flashes().count, 1, "a second flash replaces the first")
        cell.prepareForReuse()
        XCTAssertTrue(flashes().isEmpty)
    }

    func test_focusOutsideTheWindow_widensThenLands() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        XCTAssertNil(h.controller.scrollModel.index(of: "30"), "starts outside the 120-row window")
        await h.viewModel.focus(seq: 30)
        try await waitUntil(timeout: 5) { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("30")), 0, accuracy: 0.5)
    }

    func test_focusSetBeforeTheTimelineMounts_isHonoured() async throws {
        let h = TimelineHarness(attach: false)
        h.service.emit(TimelineFixtures.conversation(200))
        _ = await h.viewModel.start()
        await h.viewModel.focus(seq: 90)
        h.attach()
        try await waitUntil(timeout: 5) { h.viewModel.pendingFocusID == nil && !h.controller.hasPendingWork }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("90")), 0, accuracy: 0.5)
    }

    func test_jumpToBottom_followsAgain_andForgetsTheRememberedPosition() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(80))
        h.drag(to: 300)
        ChatScrollPositionMemory.store(roomID: h.viewModel.roomID, itemID: "10")
        h.bridge.jumpToBottom()
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: h.viewModel.roomID))
    }

    /// Controller ruling: a jump that clamps to the very bottom while the
    /// window still ends at the live tail means the user is sitting at the
    /// bottom — re-arm follow-tail rather than leaving them detached there.
    /// Row "200" is the conversation's last message, already inside the
    /// default 120-row window, so this exercises `jumpOffset(toRow:)`'s
    /// clamp directly (no widening involved).
    func test_focusOnTheLastMessage_clampsAndReArmsFollowTail() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(200))
        h.drag(to: h.maxOffset / 2)
        XCTAssertFalse(h.bridge.isFollowingTail, "must be off the tail before the jump for this to prove anything")
        await h.viewModel.focus(seq: 200)
        try await waitUntil { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertTrue(h.bridge.isFollowingTail,
                      "clamped to the bottom with the tail in the window — follow-tail must re-arm")
    }

    /// Controller ruling: no paging off the back of a jump. Focusing on the
    /// very first message lands the viewport at the true top of the loaded
    /// conversation — ordinarily an instant pagination trigger — but the
    /// apply that lands the jump must not fire it; only the user's own next
    /// scroll may.
    func test_jumpToTheTop_doesNotPageOnTheLandingApply_untilTheUserScrolls() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(300))
        await h.viewModel.focus(seq: 1)
        try await waitUntil(timeout: 5) { h.viewModel.pendingFocusID == nil }
        XCTAssertEqual(try XCTUnwrap(h.onScreenY("1")), 0, accuracy: 0.5)
        // Give any errant edge-trigger evaluation a chance to fire before
        // asserting its absence.
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.controller.extendRequestCount, 0, "the apply that lands a jump must not page")
        h.drag(to: h.collectionView.contentOffset.y + 1)
        try await waitUntil(timeout: 5) { h.controller.extendRequestCount > 0 }
    }
}

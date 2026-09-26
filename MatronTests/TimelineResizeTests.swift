import XCTest
import UIKit
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

    func test_widthChangeWhileReading_keepsTheTopMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(60))
        h.drag(to: 1200)
        let top = try XCTUnwrap(h.controller.scrollModel.topAnchor()).rowID
        resize(h, to: CGSize(width: 700, height: 700))
        try await h.settle()
        XCTAssertEqual(h.controller.scrollModel.topAnchor()?.rowID, top)
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
}

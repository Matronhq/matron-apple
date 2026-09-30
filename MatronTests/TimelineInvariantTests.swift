import XCTest
import UIKit
@testable import Matron

/// Spec §2: "Invariant check after each apply: if there are rows but no
/// visible cells, log a breadcrumb and snap to the bottom."
@MainActor
final class TimelineInvariantTests: XCTestCase {
    func test_rowsButNoVisibleCells_snapsToTheBottom() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(40))
        // Controller ruling F4: `h.drag(to:)` also ends the drag (settles),
        // and settling at the (clamped) tail re-arms follow-tail on its own —
        // so a test using it would prove nothing about the invariant. Release
        // follow-tail with a real drag begin, then set the offset directly,
        // without ever calling the end-drag settle.
        h.controller.scrollViewWillBeginDragging(h.collectionView)
        h.collectionView.contentOffset = CGPoint(x: 0, y: 100_000)
        h.collectionView.layoutIfNeeded()
        XCTAssertTrue(h.collectionView.indexPathsForVisibleItems.isEmpty)
        XCTAssertFalse(h.bridge.isFollowingTail)
        h.controller.verifyVisibleRows()
        XCTAssertEqual(h.controller.invariantSnapCount, 1)
        XCTAssertTrue(h.bridge.isFollowingTail)
        XCTAssertEqual(h.collectionView.contentOffset.y, h.maxOffset, accuracy: 0.5)
        XCTAssertFalse(h.collectionView.indexPathsForVisibleItems.isEmpty)
    }

    /// Review fix round 1, Important: `sync()` only requires `width > 0`, so
    /// rows can apply while the viewport is still 0 tall (mount, or a resize
    /// mid-flight per the controller's own comment on `pendingRestore`).
    /// Without the viewport-height guard that reads as "rows but no visible
    /// cells" and falsely snaps, even flipping follow-tail with nothing
    /// actually wrong.
    func test_zeroHeightViewport_doesNotFalsePositive() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(10))
        let followingBefore = h.bridge.isFollowingTail
        h.window.frame = CGRect(origin: .zero, size: CGSize(width: 393, height: 0))
        h.window.layoutIfNeeded()
        h.controller.view.layoutIfNeeded()
        XCTAssertEqual(h.controller.scrollModel.viewportHeight, 0)
        // A real apply while the viewport is 0 tall — new content, not a
        // manual call — is exactly the state the guard must not fire on.
        try await h.emit(TimelineFixtures.conversation(11))
        XCTAssertEqual(h.controller.invariantSnapCount, 0)
        XCTAssertEqual(h.bridge.isFollowingTail, followingBefore)
    }

    /// Review fix round 1, Minor: the test above calls `verifyVisibleRows()`
    /// directly, so deleting the call inside `apply(_:)` failed nothing.
    /// Drive several ordinary, real applies (`start`/`emit`/`drag`, no
    /// artificial offset) through the normal view-model path and confirm the
    /// wired-in check runs every time and never misfires.
    func test_realApply_wiresTheInvariantCheckAndFindsNothingWrong() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(20))
        XCTAssertEqual(h.controller.invariantSnapCount, 0)
        try await h.emit(TimelineFixtures.conversation(30))
        XCTAssertEqual(h.controller.invariantSnapCount, 0)
        h.drag(to: h.maxOffset / 2)
        try await h.emit(TimelineFixtures.conversation(45))
        XCTAssertEqual(h.controller.invariantSnapCount, 0)
    }

    /// Source pin: the forensic breadcrumbs field traces rely on.
    func test_lifecycleBreadcrumbsExist() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        // The breadcrumbs now span the controller and the shared session (plan 2026-09-28 Task 2).
        let source = try ["Matron/Features/Chat/Timeline/ChatTimelineController.swift",
                          "Shared/ChatTimeline/TimelineSession.swift"]
            .map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined(separator: "\n")
        for crumb in ["follow-tail OFF (user drag)", "follow-tail ON (settled at tail)", "follow-tail ON (own send)",
                      "follow-tail ON (jump button)", "jump → ", "restore → ", "INVARIANT rows=",
                      "timeline anchor ", "timeline dropped duplicate row ids"] {
            XCTAssertTrue(source.contains(crumb), crumb)
        }
    }
}

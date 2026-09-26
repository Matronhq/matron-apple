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

    /// Source pin: the forensic breadcrumbs field traces rely on.
    func test_lifecycleBreadcrumbsExist() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Chat/Timeline/ChatTimelineController.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for crumb in ["follow-tail OFF (user drag)", "follow-tail ON (settled at tail)", "follow-tail ON (own send)",
                      "follow-tail ON (jump button)", "jump → ", "restore → ", "INVARIANT rows=",
                      "timeline anchor ", "timeline dropped duplicate row ids"] {
            XCTAssertTrue(source.contains(crumb), crumb)
        }
    }
}

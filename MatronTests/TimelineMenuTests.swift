import XCTest
import UIKit
@testable import Matron

/// Spec §2: Copy via the collection view's context menu; native partial
/// selection inside the text (Task 17 ruling on who owns which press).
@MainActor
final class TimelineMenuTests: XCTestCase {
    private func firstTextCell(_ h: TimelineHarness) throws -> (IndexPath, TextMessageCell) {
        for indexPath in h.collectionView.indexPathsForVisibleItems.sorted() {
            if let cell = h.collectionView.cellForItem(at: indexPath) as? TextMessageCell { return (indexPath, cell) }
        }
        throw XCTSkip("no text cell on screen")
    }

    func test_contextMenu_outsideTheText_offersCopyOfTheWholeBody() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (indexPath, cell) = try firstTextCell(h)
        let outside = CGPoint(x: cell.bounds.maxX - 2, y: cell.bounds.midY)
        XCTAssertFalse(cell.isTextHit(outside))
        let point = h.collectionView.convert(outside, from: cell)
        XCTAssertNotNil(h.controller.collectionView(h.collectionView, contextMenuConfigurationForItemsAt: [indexPath],
                                                    point: point))
        let id = h.controller.appliedRowIDs[indexPath.item]
        XCTAssertEqual(h.controller.copyText(forRowID: id), cell.render?.content.body)
    }

    func test_contextMenu_onTheText_yieldsToTextSelection() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (indexPath, cell) = try firstTextCell(h)
        let textView = try XCTUnwrap(cell.segmentViewsForTesting.first)
        let inside = cell.convert(CGPoint(x: textView.bounds.midX, y: textView.bounds.midY), from: textView)
        XCTAssertTrue(cell.isTextHit(inside))
        XCTAssertNil(h.controller.collectionView(h.collectionView, contextMenuConfigurationForItemsAt: [indexPath],
                                                 point: h.collectionView.convert(inside, from: cell)))
    }

    func test_editMenu_addsCopyMessage() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let (_, cell) = try firstTextCell(h)
        let textView = try XCTUnwrap(cell.segmentViewsForTesting.first as? UITextView)
        let menu = cell.textView(textView, editMenuForTextIn: NSRange(location: 0, length: 3), suggestedActions: [])
        XCTAssertEqual(menu?.children.compactMap { ($0 as? UIAction)?.title }, ["Copy Message"])
    }

    func test_contextMenu_hostedRowsHaveNone() async throws {
        let h = TimelineHarness()
        try await h.start(with: TimelineFixtures.conversation(5))
        let separator = try XCTUnwrap(h.controller.appliedRowIDs.firstIndex { $0.hasPrefix("sep:") })
        XCTAssertNil(h.controller.collectionView(h.collectionView,
                                                 contextMenuConfigurationForItemsAt: [IndexPath(item: separator, section: 0)],
                                                 point: .zero))
    }
}

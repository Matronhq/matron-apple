import XCTest
import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import Matron

/// The native item thread on screen: where it opens, what it follows, what
/// it keeps still, and that it only builds what shows.
@MainActor
final class ItemThreadControllerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private var bottomReports: [Bool] = []

    private func model(comments count: Int, loaded: Int? = nil) -> ItemDetailView.Model {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "A long thread", body: "The item's body.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        let comments = (0..<count).map { (index: Int) -> TrackerComment in
            TrackerComment(id: "c\(index)", itemID: "it_1", author: index % 2 == 0 ? .agent : .user,
                           body: "Comment \(index).\n\n" + String(repeating: "A sentence of the reply. ", count: 12),
                           createdAt: t0.addingTimeInterval(Double(index + 1) * 60))
        }
        return .init(item: item, comments: comments, pending: [], availableResolutions: [.done], isBusy: false,
                     loadedCommentCount: loaded ?? count)
    }

    private func factory(_ model: ItemDetailView.Model, startsAtBottom: Bool = false) -> ItemThreadPieceFactory {
        let detail = ItemDetailView(model: model, draft: .constant(""), image: { _ in nil },
                                    onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                                    onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                                    now: t0.addingTimeInterval(86_400), startsAtBottom: startsAtBottom,
                                    onBottomVisibilityChange: { [weak self] in self?.bottomReports.append($0) })
        return ItemThreadPieceFactory(detail: detail, environment: TimelineHostedEnvironment())
    }

    private func mount(_ factory: ItemThreadPieceFactory, size: CGSize = CGSize(width: 390, height: 700)) throws
        -> (ItemThreadController, UIWindow) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = ItemThreadController(factory: factory)
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.update(factory: factory)
        settle(window)
        return (controller, window)
    }

    private func settle(_ window: UIWindow) {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }

    private func bottomOffset(_ controller: ItemThreadController) -> CGFloat {
        let view = controller.collectionView
        return view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
    }

    /// The screen position of a row's top.
    private func screenY(of rowID: String, in controller: ItemThreadController) throws -> CGFloat {
        let item = try XCTUnwrap(controller.itemsForTesting.first { $0.id.hasPrefix(rowID) })
        return item.frame.minY - controller.collectionView.contentOffset.y
    }

    func test_itOpensAtTheTop_andReportsItIsNotAtTheBottom() throws {
        let (controller, _) = try mount(factory(model(comments: 30)))
        XCTAssertEqual(controller.collectionView.contentOffset.y, -controller.collectionView.adjustedContentInset.top)
        XCTAssertTrue(controller.geometry.placed)
        XCTAssertTrue(controller.geometry.scrollable)
        XCTAssertFalse(controller.geometry.atBottom)
    }

    func test_aReaderWhoWasAtTheTail_opensThere() throws {
        let (controller, _) = try mount(factory(model(comments: 30), startsAtBottom: true))
        XCTAssertEqual(controller.collectionView.contentOffset.y, bottomOffset(controller), accuracy: 1)
        XCTAssertTrue(controller.geometry.atBottom)
    }

    func test_onlyWhatIsOnScreen_isBuilt() throws {
        let (controller, _) = try mount(factory(model(comments: 60)))
        XCTAssertGreaterThan(controller.itemsForTesting.count, 180)
        XCTAssertLessThan(controller.collectionView.visibleCells.count, 30)
    }

    func test_everyRowsFrame_isFinalFromTheFirstLayout() throws {
        let (controller, window) = try mount(factory(model(comments: 30)))
        let before = controller.framesForTesting
        controller.collectionView.contentOffset.y = bottomOffset(controller)
        settle(window)
        controller.collectionView.contentOffset.y = 400
        settle(window)
        XCTAssertEqual(controller.framesForTesting, before, "rows moved while scrolling")
    }

    func test_aReplyLanding_isFollowedAtTheTail() throws {
        let (controller, window) = try mount(factory(model(comments: 30), startsAtBottom: true))
        controller.update(factory: factory(model(comments: 31, loaded: 30), startsAtBottom: true))
        settle(window)
        XCTAssertEqual(controller.collectionView.contentOffset.y, bottomOffset(controller), accuracy: 1)
        XCTAssertTrue(controller.geometry.atBottom)
    }

    func test_aReplyLanding_leavesAReaderUpTheThreadWhereTheyAre() throws {
        let (controller, window) = try mount(factory(model(comments: 30)))
        controller.collectionView.contentOffset.y = 1_500
        settle(window)
        let offset = controller.collectionView.contentOffset.y
        controller.update(factory: factory(model(comments: 31, loaded: 30)))
        settle(window)
        XCTAssertEqual(controller.collectionView.contentOffset.y, offset, accuracy: 0.5)
        XCTAssertFalse(controller.geometry.atBottom)
    }

    /// A narrower window re-wraps every card above the reader; the row they
    /// were reading stays where it was on screen.
    func test_aWidthChange_keepsTheRowBeingRead_inPlace() throws {
        let (controller, window) = try mount(factory(model(comments: 30)))
        let rowID = "comment:c12"
        let item = try XCTUnwrap(controller.itemsForTesting.first { $0.id.hasPrefix(rowID) })
        controller.collectionView.contentOffset.y = item.frame.minY - 40
        settle(window)
        let before = try screenY(of: rowID, in: controller)
        let heightBefore = controller.framesForTesting.contentHeight
        window.frame.size.width = 320
        settle(window)
        XCTAssertNotEqual(controller.framesForTesting.contentHeight, heightBefore, "nothing re-wrapped")
        XCTAssertEqual(try screenY(of: rowID, in: controller), before, accuracy: 1)
    }

    func test_anUnchangedUpdate_measuresNothingAgain() throws {
        let (controller, window) = try mount(factory(model(comments: 30)))
        let measured = controller.measureCount
        XCTAssertGreaterThanOrEqual(measured, 32)
        controller.update(factory: factory(model(comments: 30)))
        settle(window)
        XCTAssertEqual(controller.measureCount, measured)
        // One new comment is one new measurement.
        controller.update(factory: factory(model(comments: 31, loaded: 30)))
        settle(window)
        XCTAssertEqual(controller.measureCount, measured + 1)
    }

    func test_reachingAndLeavingTheTail_isReportedToTheHost() throws {
        let (controller, window) = try mount(factory(model(comments: 30)))
        bottomReports = []
        controller.scrollToBottom(animated: false)
        settle(window)
        controller.collectionView.contentOffset.y = 200
        settle(window)
        XCTAssertEqual(bottomReports, [true, false])
    }

    func test_geometryReachesSwiftUI_afterTheLayoutItChangedIn() throws {
        let factory = factory(model(comments: 30))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let controller = ItemThreadController(factory: factory)
        var reports: [ItemThreadController.Geometry] = []
        controller.onGeometryChange = { reports.append($0) }
        window.rootViewController = controller
        window.isHidden = false
        addTeardownBlock { @MainActor in window.isHidden = true }
        controller.update(factory: factory)
        window.layoutIfNeeded()
        XCTAssertTrue(controller.geometry.placed)
        XCTAssertEqual(reports, [], "a state write during SwiftUI's update is dropped")
        settle(window)
        XCTAssertEqual(reports.last, ItemThreadController.Geometry(atBottom: false, scrollable: true, placed: true))
    }

    func test_losingRoom_isReported_withoutTheReaderScrolling() throws {
        // Short enough to fit the tall viewport, too long for the short one.
        let (controller, window) = try mount(factory(model(comments: 3)), size: CGSize(width: 390, height: 1400))
        XCTAssertFalse(controller.geometry.scrollable)
        window.frame.size.height = 300
        settle(window)
        XCTAssertTrue(controller.geometry.scrollable)
        XCTAssertFalse(controller.geometry.atBottom)
    }

    func test_scrollToTop_goesToTheTop_andOffersTheJumpAgain() throws {
        let (controller, window) = try mount(factory(model(comments: 30), startsAtBottom: true))
        XCTAssertTrue(controller.geometry.atBottom)
        controller.scrollToTop(animated: false)
        settle(window)
        XCTAssertEqual(controller.collectionView.contentOffset.y, -controller.collectionView.adjustedContentInset.top)
        XCTAssertFalse(controller.geometry.atBottom)
    }

    /// A long-press beside a comment's text (past its short first line)
    /// copies the whole comment; one on the words is the text view's, to
    /// select them.
    func test_aPressBesideACommentsText_copiesTheWholeComment() throws {
        let model = model(comments: 1)
        let (controller, _) = try mount(factory(model))
        let collection = controller.collectionView
        let cell = try XCTUnwrap(collection.visibleCells.compactMap { $0 as? ItemTextCell }
            .first { $0.textViewForTesting.text.hasPrefix("Comment 0.") })
        let textView = cell.textViewForTesting
        let start = textView.beginningOfDocument
        let end = try XCTUnwrap(textView.position(from: start, offset: 10))
        let line = textView.firstRect(for: try XCTUnwrap(textView.textRange(from: start, to: end)))
        let onWord = collection.convert(CGPoint(x: line.minX + 4, y: line.midY), from: textView)
        let beside = collection.convert(CGPoint(x: line.maxX + 60, y: line.midY), from: textView)
        XCTAssertLessThan(line.maxX + 60, textView.bounds.maxX, "the point is inside the text view, past the line")
        XCTAssertNil(controller.cardCopyText(at: onWord), "a press on the words selects them")
        let body = model.comments[0].body.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(controller.cardCopyText(at: beside), body)
        // The card's padding: its ground takes no touches, the card still answers.
        let ground = try XCTUnwrap(controller.itemsForTesting.first { $0.kind == .ground && $0.id == "comment:c0|ground" })
        XCTAssertEqual(controller.cardCopyText(at: CGPoint(x: ground.frame.minX + 3, y: ground.frame.midY)), body)
        XCTAssertNil(controller.cardCopyText(at: CGPoint(x: ground.frame.minX - 4, y: ground.frame.midY)),
                     "outside the card")
    }

    /// The long-press preview of a card taller than the screen is the
    /// part of it on screen: a snapshot of the whole card showed the part
    /// past the edge, which isn't drawn, as a black box.
    func test_aTallCardsPreview_isThePartOnScreen() throws {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "A long thread", body: "The item's body.",
                               originConvoID: "c1", createdAt: t0, updatedAt: t0)
        let long = TrackerComment(id: "c0", itemID: "it_1", author: .agent,
                                  body: (0..<40).map { "Paragraph \($0). A sentence of the reply that wraps." }
                                      .joined(separator: "\n\n"),
                                  createdAt: t0.addingTimeInterval(60))
        let model = ItemDetailView.Model(item: item, comments: [long], pending: [], availableResolutions: [.done],
                                         isBusy: false, loadedCommentCount: 1)
        let (controller, _) = try mount(factory(model))
        let collection = controller.collectionView
        let ground = try XCTUnwrap(controller.itemsForTesting.first { $0.kind == .ground && $0.id == "comment:c0|ground" })
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        XCTAssertGreaterThan(ground.frame.maxY, visible.maxY, "the card runs past the bottom of the screen")
        let preview = try XCTUnwrap(controller.cardPreviewFrame(row: ground.row))
        XCTAssertEqual(preview.minY, max(ground.frame.minY, visible.minY), accuracy: 0.5)
        XCTAssertEqual(preview.maxY, visible.maxY, accuracy: 0.5, "the preview stops at the screen's edge")
        XCTAssertEqual(preview.minX, ground.frame.minX)
        XCTAssertEqual(preview.width, ground.frame.width)
    }

    func test_aCardsCopyText_isItsMarkdownParts_aBlankLineApart() {
        let attachment = TrackerAttachment(blobRef: "b", mime: "image/png", name: "a.png", size: 1)
        let card = ItemCardContent(row: .comment("a"), mine: false,
                                   parts: [.markdown("First part.\n"), .attachment(attachment), .markdown("  Second.")],
                                   hasDelivery: false, hasActions: false, hostedSignature: 0)
        XCTAssertEqual(card.copyText, "First part.\n\nSecond.")
        let picturesOnly = ItemCardContent(row: .comment("b"), mine: false, parts: [.attachment(attachment)],
                                           hasDelivery: false, hasActions: false, hostedSignature: 0)
        XCTAssertNil(picturesOnly.copyText)
    }
}

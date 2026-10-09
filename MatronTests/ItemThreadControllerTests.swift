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
        let comments = (0..<count).map { index in
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
}

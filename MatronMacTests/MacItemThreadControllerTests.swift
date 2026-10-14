#if os(macOS)
import XCTest
import AppKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import MatronMac

/// The native item thread's table in a real window.
@MainActor
final class MacItemThreadControllerTests: XCTestCase {
    private var window: NSWindow!
    private var bottomReports: [Bool] = []

    override func tearDown() {
        window?.close()
        window = nil
        super.tearDown()
    }

    private func detail(_ model: ItemDetailView.Model, startsAtBottom: Bool = false) -> ItemDetailView {
        ItemDetailView(model: model, draft: ItemReplyDraft(get: { "" }, set: { _ in }), image: { _ in nil },
                       onOpenAttachment: { _ in }, onOpenLink: { _ in }, onOpenConversation: { _ in },
                       onSubmit: {}, onAttach: {}, onVoiceNote: {}, onClose: { _ in }, onReopen: {},
                       startsAtBottom: startsAtBottom,
                       onBottomVisibilityChange: { [weak self] in self?.bottomReports.append($0) })
    }

    private let selection = MessageSelectionController()

    private func factory(_ model: ItemDetailView.Model, startsAtBottom: Bool = false) -> MacItemPieceFactory {
        MacItemPieceFactory(detail: detail(model, startsAtBottom: startsAtBottom), environment: MacItemThreadEnvironment(),
                            selection: selection)
    }

    private func mount(_ model: ItemDetailView.Model, startsAtBottom: Bool = false, width: CGFloat = 600,
                       height: CGFloat = 500,
                       measurePiece: ((ItemDetailView.Piece, CGFloat) -> CGSize?)? = nil) -> MacItemThreadController {
        let controller = MacItemThreadController(factory: factory(model, startsAtBottom: startsAtBottom))
        controller.measurePieceForTesting = measurePiece
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: width, height: height))
        window.orderFront(nil)
        settle()
        return controller
    }

    private func settle(_ seconds: TimeInterval = 0.05) {
        for _ in 0..<4 {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds / 4))
            window?.contentView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
        }
    }

    private func clip(_ c: MacItemThreadController) -> NSClipView { c.scrollView.contentView }

    /// A row's top in the window's viewport: where the reader sees it.
    private func onScreenY(_ c: MacItemThreadController, row id: String) throws -> CGFloat {
        let index = try XCTUnwrap(c.rowIndex(of: id))
        return c.tableView.rect(ofRow: index).minY - clip(c).bounds.minY
    }

    private func scroll(_ c: MacItemThreadController, toTopOf id: String) throws {
        let index = try XCTUnwrap(c.rowIndex(of: id))
        clip(c).scroll(to: NSPoint(x: 0, y: c.tableView.rect(ofRow: index).minY))
        c.scrollView.reflectScrolledClipView(clip(c))
        settle()
    }

    func test_opensAtTopUnlessStartsAtBottom() {
        let top = mount(MacItemThreadFixtures.model(comments: 40))
        XCTAssertEqual(clip(top).bounds.minY, -top.scrollView.contentInsets.top, accuracy: 1)
        XCTAssertTrue(top.geometry.placed)
        XCTAssertFalse(top.geometry.atBottom)
        window.close()
        let bottom = mount(MacItemThreadFixtures.model(comments: 40), startsAtBottom: true)
        XCTAssertTrue(bottom.geometry.atBottom)
        XCTAssertEqual(clip(bottom).bounds.maxY, bottom.tableView.frame.maxY + bottom.scrollView.contentInsets.bottom,
                       accuracy: 1)
    }

    func test_buildsOnlyRowsOnScreen() {
        let c = mount(MacItemThreadFixtures.model(comments: 80))
        XCTAssertGreaterThan(c.rowCount, 80)
        XCTAssertLessThan(c.builtCellCount, 15)
    }

    func test_unchangedUpdateMeasuresNothing() {
        let model = MacItemThreadFixtures.model(comments: 20)
        let c = mount(model)
        let measured = c.measureCount
        c.update(factory: factory(model))
        settle()
        XCTAssertEqual(c.measureCount, measured)
    }

    func test_newCommentAtBottomFollows() {
        let c = mount(MacItemThreadFixtures.model(comments: 30), startsAtBottom: true)
        XCTAssertTrue(c.geometry.atBottom)
        c.update(factory: factory(MacItemThreadFixtures.model(comments: 31), startsAtBottom: true))
        settle()
        XCTAssertTrue(c.geometry.atBottom)
        XCTAssertEqual(clip(c).bounds.maxY, c.tableView.frame.maxY + c.scrollView.contentInsets.bottom, accuracy: 1)
    }

    func test_newCommentWhenScrolledUpDoesNotMove() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 30))
        try scroll(c, toTopOf: "comment:c10")
        let before = try onScreenY(c, row: "comment:c10")
        c.update(factory: factory(MacItemThreadFixtures.model(comments: 31)))
        settle()
        XCTAssertEqual(try onScreenY(c, row: "comment:c10"), before, accuracy: 1)
        XCTAssertFalse(c.geometry.atBottom)
    }

    func test_rowAboveGrowingKeepsAnchor() throws {
        let model = MacItemThreadFixtures.model(comments: 50)
        let c = mount(model)
        try scroll(c, toTopOf: "comment:c40")
        let before = try onScreenY(c, row: "comment:c40")
        var grown = model
        grown.comments[10] = MacItemThreadFixtures.comment(10, body: String(repeating: MacItemThreadFixtures.paragraph + "\n\n", count: 3))
        c.update(factory: factory(grown))
        settle()
        XCTAssertEqual(try onScreenY(c, row: "comment:c40"), before, accuracy: 1)
    }

    func test_widthChangeKeepsAnchorAndMeasuresOnce() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 40))
        try scroll(c, toTopOf: "comment:c20")
        let measured = c.measureCount
        window.setContentSize(NSSize(width: 700, height: 500))
        settle(0.3)
        XCTAssertLessThanOrEqual(c.measureCount - measured, c.rowCount)
        XCTAssertEqual(try onScreenY(c, row: "comment:c20"), 0, accuracy: 2)
    }

    /// A piece measured off-window shorter than it draws: the cell reports
    /// its real height and the row grows, pushing the rows below down.
    func test_hostedPieceGrowthMovesRowsBelowWithoutOverlap() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 5)) { piece, width in
            if case .caption = piece { return CGSize(width: 100, height: 2) }
            return nil
        }
        let index = try XCTUnwrap(c.rowIndex(of: "comment:c1"))
        let measuredWrong = 2 + MacItemCardGeometry.partSpacing
        // Before the report lands, the card was laid out with a 2-point
        // caption; after it, with the caption's real height.
        settle(0.2)
        let rect = c.tableView.rect(ofRow: index)
        let card = try XCTUnwrap(c.tableView.view(atColumn: 0, row: index, makeIfNecessary: false) as? MacItemCardCell)
        let body = try XCTUnwrap(card.visibleBodies.first)
        let caption = try XCTUnwrap(card.visibleHostFrames.first)
        XCTAssertGreaterThan(caption.height, measuredWrong)
        XCTAssertGreaterThanOrEqual(body.frame.minY, caption.maxY + MacItemCardGeometry.partSpacing - 0.5)
        XCTAssertLessThanOrEqual(card.groundFrame.maxY, rect.height - ItemTypography.threadSpacing + 0.5)
        let next = c.tableView.rect(ofRow: index + 1)
        XCTAssertGreaterThanOrEqual(next.minY, rect.maxY - 0.5)
    }

    func test_inPlaceItemSwapResets() throws {
        let c = mount(MacItemThreadFixtures.model(id: "it_a", comments: 40))
        try scroll(c, toTopOf: "comment:c20")
        c.update(factory: factory(MacItemThreadFixtures.model(id: "it_b", comments: 3)))
        settle()
        XCTAssertEqual(c.rowCount, c.tableView.numberOfRows)
        XCTAssertEqual(clip(c).bounds.minY, -c.scrollView.contentInsets.top, accuracy: 1)
        XCTAssertNil(c.rowIndex(of: "comment:c20"))
    }

    /// A title long enough to wrap: the hosted header keeps the height the
    /// sizer measured at the row's width, not one measured unwrapped.
    func test_wrappedTitleKeepsItsMeasuredHeight() throws {
        let title = String(repeating: "A long item title that wraps across the reading column ", count: 3)
        let model = MacItemThreadFixtures.model(comments: 3, title: title)
        let c = mount(model)
        settle(0.3)
        let index = try XCTUnwrap(c.rowIndex(of: ItemThreadRow.header.id))
        let rowWidth = c.tableView.rect(ofRow: index).width
        let measured = MacItemPieceSizer().size(of: factory(model).view(.row(.header)), maxWidth: rowWidth).height
        XCTAssertGreaterThan(measured, 60, "the title wraps")
        XCTAssertEqual(c.tableView.rect(ofRow: index).height, measured + ItemTypography.threadSpacing, accuracy: 1)
    }

    /// AppKit keeps cells mounted just off screen; after a width change
    /// they are laid out for the new width too, not only the visible ones.
    func test_widthChangeUpdatesMountedRowsOffScreen() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 40))
        try scroll(c, toTopOf: "comment:c20")
        try scroll(c, toTopOf: "comment:c22")
        window.setContentSize(NSSize(width: 420, height: 500))
        settle(0.3)
        c.catchUpWidth()
        settle()
        var checked = 0
        var offScreen = 0
        for row in 0..<c.tableView.numberOfRows {
            guard let cell = c.tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MacItemCardCell else { continue }
            checked += 1
            if !c.tableView.visibleRect.intersects(c.tableView.rect(ofRow: row)) { offScreen += 1 }
            XCTAssertEqual(cell.groundFrame, c.cardFrameForTesting(row: row), "row \(row)")
        }
        XCTAssertGreaterThan(checked, 0)
        XCTAssertGreaterThan(offScreen, 0, "the table kept no cells off screen; the test proves nothing")
    }

    /// A divider drag steps the width every frame: each step measures the
    /// rows near the screen only; the rest follow once, when it settles.
    func test_widthStepMeasuresOnlyRowsNearScreen() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 80))
        c.widthCatchUpDelay = 60
        try scroll(c, toTopOf: "comment:c40")
        let before = c.measureCount
        window.setContentSize(NSSize(width: 560, height: 500))
        settle(0.2)
        XCTAssertLessThan(c.measureCount - before, 40, "a step re-measured the whole thread")
        XCTAssertGreaterThan(c.staleRowCountForTesting, 0)
        XCTAssertEqual(try onScreenY(c, row: "comment:c40"), 0, accuracy: 2)
        c.catchUpWidth()
        settle()
        XCTAssertEqual(c.staleRowCountForTesting, 0)
        XCTAssertLessThanOrEqual(c.measureCount - before, c.rowCount)
        XCTAssertEqual(try onScreenY(c, row: "comment:c40"), 0, accuracy: 2)
    }

    func test_reportsBottomVisibility() throws {
        let c = mount(MacItemThreadFixtures.model(comments: 30))
        settle()
        bottomReports = []
        c.scrollToBottom()
        settle()
        XCTAssertEqual(bottomReports.last, true)
        try scroll(c, toTopOf: "comment:c2")
        XCTAssertEqual(bottomReports.last, false)
    }
}
#endif

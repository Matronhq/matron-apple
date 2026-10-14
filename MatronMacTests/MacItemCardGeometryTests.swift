#if os(macOS)
import XCTest
import AppKit
import MatronDesignSystem
import MatronModels
@testable import MatronMac

@MainActor
final class MacItemCardGeometryTests: XCTestCase {
    /// A hosted piece is 20 pt tall and as wide as offered, except a
    /// caption, which hugs at 120.
    private let hosted: (ItemDetailView.Piece, CGFloat) -> CGSize = { piece, width in
        if case .caption = piece { return CGSize(width: 120, height: 20) }
        return CGSize(width: width, height: 20)
    }

    private func card(_ parts: [ItemCardContent.Part], row: ItemThreadRow = .body, delivery: Bool = false,
                      actions: Bool = false, statusLine: Bool = false) -> ItemCardContent {
        ItemCardContent(row: row, mine: false, parts: parts, hasDelivery: delivery, hasActions: actions,
                        hostedSignature: 0, hasStatusLine: statusLine)
    }

    func test_partsRunTopToBottomWithoutOverlapping() {
        let layout = MacItemCardGeometry.layout(
            card([.markdown("One"), .attachment(MacItemThreadFixtures.image("b1")), .markdown("Two")],
                 row: .comment("c1"), delivery: true, actions: true),
            textSelectionIDs: ["c1", "c1#seg1"], rowWidth: 800, hostedSize: hosted)
        for (a, b) in zip(layout.frames, layout.frames.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.001, "\(a) overlaps \(b)")
        }
        XCTAssertEqual(layout.height, ceil(layout.frames.last!.maxY), accuracy: 0.001)
    }

    func test_columnIsCappedAtTheMeasureAndCentred() {
        let wide = MacItemCardGeometry.column(rowWidth: 1200)
        XCTAssertEqual(wide.width, ItemTypography.measure)
        XCTAssertEqual(wide.x, (1200 - ItemTypography.measure) / 2)
        let narrow = MacItemCardGeometry.column(rowWidth: 500)
        XCTAssertEqual(narrow.width, 500 - 2 * ItemTypography.threadPadding)
    }

    func test_partsAreCaptionThenTextThenDeliveryInsideTheCard_buttonsBelow() {
        let layout = MacItemCardGeometry.layout(card([.markdown("Hello")], row: .comment("c1"), delivery: true, actions: true),
                                                textSelectionIDs: ["c1"], rowWidth: 800, hostedSize: hosted)
        XCTAssertEqual(layout.parts, [.hosted(.caption(.comment("c1"))), .text(selectionID: "c1", source: "Hello"),
                                      .hosted(.delivery(commentID: "c1")), .hosted(.commentActions(commentID: "c1"))])
        let card = layout.cardFrame
        XCTAssertEqual(layout.frames[0].minY, card.minY + ItemTypography.cardPadding)
        XCTAssertEqual(layout.frames[1].minY, layout.frames[0].maxY + 6)
        XCTAssertEqual(card.maxY, layout.frames[2].maxY + ItemTypography.cardPadding)
        XCTAssertEqual(layout.frames[3].minY, card.maxY + ItemTypography.threadSpacing)
    }

    func test_statusLineSitsAboveTheCard() {
        let layout = MacItemCardGeometry.layout(card([.markdown("Closing note")], row: .comment("c1"), statusLine: true),
                                                textSelectionIDs: ["c1"], rowWidth: 800, hostedSize: hosted)
        XCTAssertEqual(layout.parts.first, .hosted(.statusLine(commentID: "c1")))
        XCTAssertEqual(layout.cardFrame.minY, layout.frames[0].maxY + ItemDetailView.statusNoteSpacing)
    }

    func test_cardHugsItsWidestPiece() {
        let layout = MacItemCardGeometry.layout(card([.markdown("Hi")]), textSelectionIDs: ["body:it"],
                                                rowWidth: 800, hostedSize: hosted)
        XCTAssertEqual(layout.cardFrame.width, 120 + 2 * ItemTypography.cardPadding, accuracy: 0.5)
        XCTAssertEqual(layout.cardFrame.minX, MacItemCardGeometry.column(rowWidth: 800).x)
    }

    func test_textSelectionIDs_countEveryTextSegment() {
        let ids = MacItemCardGeometry.textSelectionIDs(cardID: "body:it", body: "Before\n\n![a](attachment:b1)\n\nAfter",
                                                       attachments: [MacItemThreadFixtures.image("b1")])
        XCTAssertEqual(ids, ["body:it", "body:it#seg1"])
    }

    /// What the table measures is what the text view lays out: TextKit 1
    /// on both sides, at the same width.
    func test_textFrameHeightEqualsTheLaidOutBody() throws {
        let source = """
            ## A heading

            A paragraph that wraps over more than one line at this width, with **bold** and a [link](https://example.com).

            - one
            - two

            ```swift
            let x = 1
            ```

            | a | b |
            |---|---|
            | 1 | 2 |
            """
        let layout = MacItemCardGeometry.layout(card([.markdown(source)]), textSelectionIDs: ["body:it"],
                                                rowWidth: 700, hostedSize: hosted)
        let frame = layout.frames[1]
        let body = MessageBodyView()
        body.forcesTextKit1 = true
        body.frame = frame
        body.configure(source: source, rendered: MarkdownAttributed.rendered(for: source, style: .item, cache: true),
                       itemID: "body:it", selectionController: nil)
        body.layoutSubtreeIfNeeded()
        let manager = try XCTUnwrap(body.textView.layoutManager)
        let container = try XCTUnwrap(body.textView.textContainer)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height + 2 * body.textView.textContainerInset.height
        XCTAssertEqual(used, frame.height, accuracy: 1)
    }
}
#endif

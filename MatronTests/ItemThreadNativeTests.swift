import XCTest
import UIKit
import SwiftUI
import MatronDesignSystem
import MatronModels
@testable import Matron

/// The native item thread's pure parts: what each row draws, where a
/// card's pieces go, and where the rows go.
@MainActor
final class ItemThreadNativeTests: XCTestCase {
    private let style = ItemThreadTextStyle(sizeCategory: .large)

    private func model(body: String = "The body.", comments: [TrackerComment] = [],
                       queued: [String: QueuedReplyState] = [:]) -> ItemDetailView.Model {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "A question", body: body, originConvoID: "c1",
                               createdAt: Date(timeIntervalSince1970: 1_770_000_000),
                               updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
        return .init(item: item, comments: comments, pending: [], availableResolutions: [.done], isBusy: false,
                     queuedReplies: queued)
    }

    private func contents(_ model: ItemDetailView.Model, answers: Bool = true) -> [ItemThreadRowContent] {
        ItemThreadContentBuilder.contents(rows: ItemDetailView.rows(for: model, offersActions: true), model: model,
                                          answersCommentActions: answers)
    }

    private func card(_ content: ItemThreadRowContent?) -> ItemCardContent? {
        if case .card(let card)? = content { return card }
        return nil
    }

    // MARK: Contents

    func test_theBodyAndComments_areCards_theRestIsHosted() {
        let comments = [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "A reply."),
                        TrackerComment(id: "s", itemID: "it_1", author: .agent, kind: .status, body: "")]
        let built = contents(model(comments: comments))
        XCTAssertEqual(built.map(\.row), [.header, .body, .divider, .comment("a"), .comment("s")])
        XCTAssertNil(card(built[0]))
        XCTAssertEqual(card(built[1])?.mine, false)
        XCTAssertEqual(card(built[3])?.mine, true)
        XCTAssertNil(card(built[4]), "a status row is drawn by the SwiftUI row")
    }

    func test_aCardsParts_keepInlineAttachmentsInPlace_andTrailingOnesLast() {
        let inline = TrackerAttachment(blobRef: "b1", mime: "image/png", name: "one.png", size: 1)
        let trailing = TrackerAttachment(blobRef: "b2", mime: "image/png", name: "two.png", size: 1)
        let parts = ItemThreadContentBuilder.parts(body: "Before\n\n![one](attachment:b1)\n\nAfter",
                                                   attachments: [inline, trailing])
        XCTAssertEqual(parts, [.markdown("Before"), .attachment(inline), .markdown("After"), .attachment(trailing)])
    }

    func test_aReplyTheAgentHasNotGot_drawsItsDeliveryLine() {
        let comments = [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "Queued.")]
        XCTAssertEqual(card(contents(model(comments: comments, queued: ["a": .sending]))[3])?.hasDelivery, true)
        XCTAssertEqual(card(contents(model(comments: comments))[3])?.hasDelivery, false)
    }

    func test_aCommentsButtons_needAnAnswerer() {
        let comments = [TrackerComment(id: "a", itemID: "it_1", author: .agent, body: "Which?", actions: ["One", "Two"])]
        XCTAssertEqual(card(contents(model(comments: comments))[3])?.hasActions, true)
        XCTAssertEqual(card(contents(model(comments: comments), answers: false)[3])?.hasActions, false)
    }

    /// Unchanged content is equal, so its measurement is reused; a changed
    /// delivery state is not.
    func test_contentEquality_followsWhatIsDrawn() {
        let comments = [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "Queued.")]
        XCTAssertEqual(contents(model(comments: comments)), contents(model(comments: comments)))
        XCTAssertNotEqual(contents(model(comments: comments, queued: ["a": .sending])),
                          contents(model(comments: comments, queued: ["a": .cancelling])))
    }

    // MARK: Card geometry

    private func render(_ content: ItemCardContent, rowWidth: CGFloat = 400,
                        hosted: CGSize = CGSize(width: 90, height: 16)) -> ItemCardRender {
        ItemCardRenderer.render(content, rowWidth: rowWidth, style: style) { _, _ in hosted }
    }

    private func content(_ parts: [ItemCardContent.Part], row: ItemThreadRow = .comment("a"),
                         delivery: Bool = false, actions: Bool = false) -> ItemCardContent {
        ItemCardContent(row: row, mine: false, parts: parts, hasDelivery: delivery, hasActions: actions, hostedSignature: 0)
    }

    func test_theColumn_isPadded_capped_andCentred() {
        XCTAssertEqual(ItemCardRenderer.column(rowWidth: 400).x, 16)
        XCTAssertEqual(ItemCardRenderer.column(rowWidth: 400).width, 368)
        XCTAssertEqual(ItemCardRenderer.column(rowWidth: 1000).width, ItemTypography.measure)
        XCTAssertEqual(ItemCardRenderer.column(rowWidth: 1000).x, (1000 - ItemTypography.measure) / 2)
    }

    func test_aCard_hugsItsText_upToTheColumn() {
        let short = render(content([.markdown("ok")]))
        XCTAssertLessThan(short.cardFrame.width, 200)
        XCTAssertEqual(short.cardFrame.minX, 16)
        let long = render(content([.markdown(String(repeating: "word ", count: 80))]))
        // As wide as its longest wrapped line, never wider than the column.
        XCTAssertGreaterThan(long.cardFrame.width, 320)
        XCTAssertLessThanOrEqual(long.cardFrame.width, 368)
    }

    func test_pieces_stackInsideTheCardsPadding_withoutOverlap() {
        let rendered = render(content([.markdown("One paragraph.\n\n```\ncode\n```\n\nAnother.")], delivery: true))
        let frames = rendered.pieces.map(\.frame)
        XCTAssertEqual(frames.first?.minY, ItemTypography.cardPadding)
        for (above, below) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(below.minY, above.maxY, "pieces overlap")
        }
        XCTAssertEqual(rendered.cardFrame.maxY, (frames.last?.maxY ?? 0) + ItemTypography.cardPadding)
        XCTAssertEqual(rendered.height, ceil(rendered.cardFrame.maxY))
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, rendered.cardFrame.minX + ItemTypography.cardPadding)
            XCTAssertLessThanOrEqual(frame.maxX, 16 + 368 - ItemTypography.cardPadding + 0.5)
        }
    }

    func test_aCommentsButtons_sitAThreadGapUnderTheCard() {
        let rendered = render(content([.markdown("Which?")], actions: true))
        let buttons = try? XCTUnwrap(rendered.pieces.last)
        XCTAssertEqual(buttons?.frame.minY, rendered.cardFrame.maxY + ItemTypography.threadSpacing)
        XCTAssertEqual(rendered.height, ceil(buttons?.frame.maxY ?? 0))
    }

    /// What is measured is what is drawn: a live text view given a piece's
    /// text at its frame's width needs exactly its frame's height.
    func test_textPieces_areMeasuredAsTheyAreDrawn() throws {
        let markdown = "A **bold** start, then a long sentence that wraps over several lines in a phone card.\n\n"
            + "- a list item that also wraps on to a second line in this width\n- a short one\n\nThe end."
        let rendered = render(content([.markdown(markdown)]), rowWidth: 320)
        let texts = rendered.pieces.compactMap { piece -> (NSAttributedString, CGRect)? in
            if case .text(let text) = piece.kind { return (text, piece.frame) }
            return nil
        }
        XCTAssertFalse(texts.isEmpty)
        for (text, frame) in texts {
            let view = TimelineTextViewFactory.make()
            view.attributedText = text
            let fitted = view.sizeThatFits(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
            XCTAssertEqual(ceil(fitted.height), frame.height, accuracy: 1)
        }
    }

    // MARK: Text runs

    private func prose(_ markdown: String) -> NSAttributedString {
        for segment in MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: false).segments {
            if case .text(let text) = segment { return text }
        }
        return NSAttributedString()
    }

    func test_shortProse_isOneRun() {
        let runs = ItemTextRuns.split(prose("One short paragraph.\n\nAnd another."))
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.gapBefore, 0)
    }

    /// Long prose splits at paragraph ends only, loses no text, and takes
    /// the height it took whole.
    func test_longProse_splitsAtParagraphs_andKeepsItsHeight() {
        let paragraph = String(repeating: "A sentence of ordinary length that wraps in a phone card. ", count: 4)
        let markdown = (0..<8).map { "\($0). " + paragraph }.joined(separator: "\n\n")
            + "\n\n- a list item\n- another list item\n\nThe end."
        let whole = prose(markdown)
        let runs = ItemTextRuns.split(whole)
        XCTAssertGreaterThan(runs.count, 4)
        XCTAssertEqual(runs.map(\.run.string).joined(separator: "\n"),
                       whole.string.trimmingCharacters(in: .newlines))
        for run in runs { XCTAssertFalse(run.run.string.hasSuffix("\n")) }
        let width: CGFloat = 320
        let split = runs.reduce(CGFloat(0)) { $0 + $1.gapBefore + TextKitMeasure.measure($1.run, width: width).size.height }
        XCTAssertEqual(split, TextKitMeasure.measure(whole, width: width).size.height, accuracy: CGFloat(runs.count))
    }

    // MARK: Tables

    private func table(_ markdown: String) throws -> ItemTableLayout {
        for segment in MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: false).segments {
            if case .table(let table) = segment { return ItemTableLayout(table: table) }
        }
        throw XCTSkip("no table parsed")
    }

    func test_aTable_sizesColumnsToTheirText_cappedBeforeTheyWrap() throws {
        let long = String(repeating: "word ", count: 60)
        let layout = try table("| K | V |\n|---|---|\n| a | \(long)|\n| b | 2 |")
        XCTAssertLessThan(layout.columnWidths[0], 60)
        // As wide as its longest wrapped line, which the cap bounds.
        XCTAssertGreaterThan(layout.columnWidths[1], 240)
        XCTAssertLessThanOrEqual(layout.columnWidths[1], ItemTypography.tableCellMaxWidth + 16)
        // The wrapped row is several lines tall; the others one.
        XCTAssertGreaterThan(layout.rowHeights[1], layout.rowHeights[2] * 3)
        XCTAssertEqual(layout.rowHeights[0], layout.rowHeights[2], accuracy: 2)
        XCTAssertEqual(layout.size.width, layout.columnXs[1] + layout.columnWidths[1] + 1)
        XCTAssertEqual(layout.size.height, layout.rowYs[2] + layout.rowHeights[2] + 1)
    }

    func test_aTablesText_staysInsideItsCell_placedByItsColumnsAlignment() throws {
        let layout = try table("| A wide header | Another wide one |\n|:---|---:|\n| x | y |")
        for row in 0..<2 {
            for column in 0..<2 {
                XCTAssertTrue(layout.cellFrame(row: row, column: column).insetBy(dx: -0.5, dy: -0.5)
                    .contains(layout.textFrame(row: row, column: column)))
            }
        }
        XCTAssertEqual(layout.textFrame(row: 1, column: 0).minX, layout.cellFrame(row: 1, column: 0).minX + 8)
        XCTAssertEqual(layout.textFrame(row: 1, column: 1).maxX, layout.cellFrame(row: 1, column: 1).maxX - 8)
    }

    func test_aTablesHeaderRow_isSemibold() throws {
        let layout = try table("| Head |\n|---|\n| body |")
        func weight(_ text: NSAttributedString) -> CGFloat {
            let font = text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
            let traits = font?.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
            return traits?[.weight] as? CGFloat ?? 0
        }
        XCTAssertGreaterThan(weight(layout.texts[0][0]), weight(layout.texts[1][0]))
    }

    func test_aLinkInACell_isFoundWhereItIsDrawn_andNowhereElse() throws {
        let layout = try table("| A |\n|---|\n| [link](https://example.com/x) |\n| plain |")
        let onLink = layout.textFrame(row: 1, column: 0)
        XCTAssertEqual(layout.link(at: CGPoint(x: onLink.minX + 4, y: onLink.midY))?.absoluteString, "https://example.com/x")
        let plain = layout.textFrame(row: 2, column: 0)
        XCTAssertNil(layout.link(at: CGPoint(x: plain.minX + 4, y: plain.midY)))
        XCTAssertNil(layout.link(at: CGPoint(x: -5, y: -5)))
    }

    // MARK: Row frames

    func test_rows_areAThreadGapApart_insideThePadding() {
        let frames = ItemThreadFrames(heights: [40, 0, 100])
        // 16 padding, then each row 18 below the last.
        XCTAssertEqual(frames.minYs, [16, 74, 92] as [CGFloat])
        // After the last row: a gap, the one-point tail, the padding.
        XCTAssertEqual(frames.contentHeight, 227)
        XCTAssertEqual(frames.frame(at: 2, width: 320), CGRect(x: 0, y: 92, width: 320, height: 100))
    }

    func test_firstRowEndingAfter_findsTheRowAtAnOffset() {
        let frames = ItemThreadFrames(heights: [40, 60, 100])
        XCTAssertEqual(frames.firstRow(endingAfter: 0), 0)
        XCTAssertEqual(frames.firstRow(endingAfter: 56), 1)
        XCTAssertEqual(frames.firstRow(endingAfter: 10_000), nil)
    }

    // MARK: The switch

    func test_theSwitch_readsItsDefault_untilSet() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "item-thread-flag-tests"))
        defaults.removePersistentDomain(forName: "item-thread-flag-tests")
        XCTAssertEqual(ItemThreadFlag.isOn(defaults), ItemThreadFlag.defaultValue)
        defaults.set(!ItemThreadFlag.defaultValue, forKey: ItemThreadFlag.key)
        XCTAssertEqual(ItemThreadFlag.isOn(defaults), !ItemThreadFlag.defaultValue)
    }
}

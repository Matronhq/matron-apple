import XCTest
import UIKit
import SwiftUI
@testable import MatronDesignSystem
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

    /// On the phone the header draws the links itself and leaves the
    /// labels out, so neither adds a row under it; a link change still
    /// measures the header again.
    func test_labelsAndLinks_addNoRow_andALinkChangeRedrawsTheHeader() {
        var linked = model()
        linked.item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "A question", body: "The body.",
                                  labels: ["uploads"], links: [TrackerLink(url: "https://example.com/pull/1", title: "PR 1")],
                                  originConvoID: "c1", createdAt: Date(timeIntervalSince1970: 1_770_000_000),
                                  updatedAt: Date(timeIntervalSince1970: 1_770_000_000))
        let built = contents(linked)
        XCTAssertEqual(built.map(\.row), [.header, .body, .divider])
        XCTAssertNotEqual(built.first, contents(model()).first, "the header row is measured again for its links")
    }

    /// The header's caption rows share a line while they fit, wrap when
    /// the next one does not, and a row wider than the line gets the line.
    func test_theHeadersCaptionRows_sitSideBySide_whileTheyFit() {
        let frames = ItemHeaderFlow.frames(for: [CGSize(width: 150, height: 16), CGSize(width: 100, height: 16),
                                                 CGSize(width: 120, height: 16), CGSize(width: 500, height: 16)],
                                           width: 370, spacing: 14, lineSpacing: 4)
        XCTAssertEqual(frames, [CGRect(x: 0, y: 0, width: 150, height: 16), CGRect(x: 164, y: 0, width: 100, height: 16),
                                CGRect(x: 0, y: 20, width: 120, height: 16), CGRect(x: 0, y: 40, width: 370, height: 16)])
    }

    /// The working indicator is a hosted row at the foot of the thread,
    /// measured again when its label changes.
    func test_theWorkingIndicator_isAHostedRow_atTheFoot() {
        var busy = model(comments: [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "A reply.")])
        XCTAssertFalse(contents(busy).map(\.row).contains(.working))
        busy.working = .starting
        let starting = contents(busy)
        XCTAssertEqual(starting.last?.row, .working)
        XCTAssertNil(card(starting.last))
        busy.working = .working
        XCTAssertNotEqual(contents(busy).last, starting.last)
    }

    /// The note left when closing is a card under its line; it draws the
    /// attachments its text places and no others, and has no buttons.
    func test_aStatusNote_isACardUnderItsLine() {
        let done = TrackerItem.StatusSnapshot(state: .closed, resolution: .done, awaiting: nil)
        let file = TrackerAttachment(blobRef: "b1", mime: "application/pdf", name: "one.pdf", size: 1)
        let comments = [TrackerComment(id: "s", itemID: "it_1", author: .agent, kind: .status, body: "All done.",
                                       attachments: [file], statusTo: done, actions: ["One"]),
                        TrackerComment(id: "u", itemID: "it_1", author: .agent, kind: .status, body: "Changed.")]
        let built = contents(model(comments: comments))
        XCTAssertEqual(card(built[3])?.hasStatusLine, true)
        XCTAssertEqual(card(built[3])?.parts, [.markdown("All done.")])
        XCTAssertEqual(card(built[3])?.hasActions, false)
        XCTAssertEqual(card(built[4])?.hasStatusLine, true, "a change the line cannot name still says the item changed")
    }

    func test_aStatusNotesLine_spansTheColumn_overItsCard() {
        var note = content([.markdown("All done.")])
        note.hasStatusLine = true
        let rendered = render(note)
        let line = rendered.pieces[0].frame
        XCTAssertEqual(line, CGRect(x: 16, y: 0, width: 368, height: 16))
        XCTAssertEqual(rendered.cardFrame.minY, line.maxY + ItemDetailView.statusNoteSpacing)
        XCTAssertEqual(rendered.pieces[1].frame.minY, rendered.cardFrame.minY + ItemTypography.cardPadding)
        XCTAssertEqual(rendered.height, ceil(rendered.cardFrame.maxY))
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

    /// Under a minute a caption says "now", never a count of seconds; a
    /// date a little ahead of the clock (another device's) is "now" too.
    func test_aCaptionUnderAMinuteOld_saysNow() {
        let t = Date(timeIntervalSince1970: 1_770_000_000)
        XCTAssertEqual(ItemDetailView.relativeDate(t, now: t), "now")
        XCTAssertEqual(ItemDetailView.relativeDate(t, now: t.addingTimeInterval(42)), "now")
        XCTAssertEqual(ItemDetailView.relativeDate(t, now: t.addingTimeInterval(59.9)), "now")
        XCTAssertEqual(ItemDetailView.relativeDate(t.addingTimeInterval(5), now: t), "now")
        let minute = ItemDetailView.relativeDate(t, now: t.addingTimeInterval(60))
        XCTAssertNotEqual(minute, "now")
        XCTAssertTrue(minute.contains("1"), minute)
        XCTAssertFalse(ItemDetailView.relativeDate(t, now: t.addingTimeInterval(600)).contains("sec"))
    }

    /// The caption's date is part of a card's content: while it reads the
    /// same the card keeps its measurement, and once it has grown the card
    /// is measured again, so the caption never runs past its edge.
    func test_aCardsCaptionDate_isPartOfItsContent() {
        let t = Date(timeIntervalSince1970: 1_770_000_000)
        let reply = [TrackerComment(id: "a", itemID: "it_1", author: .user, body: "Merge", createdAt: t, action: "Merge")]
        func built(_ seconds: TimeInterval) -> ItemCardContent? {
            card(ItemThreadContentBuilder.contents(rows: ItemDetailView.rows(for: model(comments: reply), offersActions: true),
                                                   model: model(comments: reply), answersCommentActions: true,
                                                   now: t.addingTimeInterval(seconds))[3])
        }
        XCTAssertEqual(built(2)?.captionDate, "now")
        XCTAssertEqual(built(2), built(42), "still \"now\": the measurement is reused")
        XCTAssertNotEqual(built(42), built(12 * 60), "the date grew: measured again")
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

    /// The card's caption, body and delivery line stack inside its
    /// padding; the body's code block lies on one of its lines, inside it.
    func test_pieces_stackInsideTheCardsPadding_withBlocksOnTheBodysLines() throws {
        let rendered = render(content([.markdown("One paragraph.\n\n```\ncode\n```\n\nAnother.")], delivery: true))
        let body = try XCTUnwrap(rendered.pieces.first { if case .body = $0.kind { true } else { false } })
        let stacked = rendered.pieces.filter { piece in
            switch piece.kind {
            case .code, .table: return false
            default: return true
            }
        }
        let frames = stacked.map(\.frame)
        XCTAssertEqual(frames.first?.minY, ItemTypography.cardPadding)
        for (above, below) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(below.minY, above.maxY, "pieces overlap")
        }
        let code = try XCTUnwrap(rendered.pieces.first { if case .code = $0.kind { true } else { false } })
        XCTAssertTrue(body.frame.insetBy(dx: -0.5, dy: -0.5).contains(code.frame), "the code is off the body")
        XCTAssertGreaterThan(code.frame.minY, body.frame.minY, "the code is not after the first paragraph")
        XCTAssertLessThan(code.frame.maxY, body.frame.maxY, "the code is not before the last paragraph")
        XCTAssertEqual(rendered.cardFrame.maxY, (frames.last?.maxY ?? 0) + ItemTypography.cardPadding)
        XCTAssertEqual(rendered.height, ceil(rendered.cardFrame.maxY))
        for frame in rendered.pieces.map(\.frame) {
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

    private func body(of rendered: ItemCardRender) -> (ItemCardBody, CGRect)? {
        for piece in rendered.pieces { if case .body(let body) = piece.kind { return (body, piece.frame) } }
        return nil
    }

    /// What is measured is what is drawn: a live text view given the
    /// body's text at its frame's width needs exactly its frame's height,
    /// and each block's line is where its view is.
    func test_theBody_isMeasuredAsItIsDrawn() throws {
        let markdown = "A **bold** start, then a long sentence that wraps over several lines in a phone card.\n\n"
            + "- a list item that also wraps on to a second line in this width\n- a short one\n\n"
            + "```\nlet x = 1\nlet y = 2\n```\n\nThe end."
        let rendered = render(content([.markdown(markdown)]), rowWidth: 320)
        let (body, frame) = try XCTUnwrap(body(of: rendered))
        let view = TimelineTextViewFactory.make()
        view.attributedText = body.body.text
        view.frame = CGRect(origin: .zero, size: frame.size)
        let fitted = view.sizeThatFits(CGSize(width: frame.width, height: .greatestFiniteMagnitude))
        XCTAssertEqual(ceil(fitted.height), frame.height, accuracy: 1)
        view.layoutIfNeeded()
        let block = try XCTUnwrap(body.body.blocks.first)
        let start = try XCTUnwrap(view.position(from: view.beginningOfDocument, offset: block.location))
        let end = try XCTUnwrap(view.position(from: start, offset: 1))
        let line = view.firstRect(for: try XCTUnwrap(view.textRange(from: start, to: end)))
        XCTAssertEqual(line.minY, body.blockFrames[0].minY, accuracy: 1.5)
    }

    /// Long prose, a code block, a table and an attachment are one string,
    /// so a selection runs through all of them; a copy has each block's
    /// own text in its place, and leaves the attachment out.
    func test_aLongCard_isOneBody_whoseCopyHasEachBlocksText() throws {
        let paragraph = String(repeating: "A sentence of ordinary length that wraps in a phone card. ", count: 4)
        let markdown = (0..<8).map { "\($0). " + paragraph }.joined(separator: "\n\n")
            + "\n\n```\nlet x = 1\n```\n\n| A | B |\n|---|---|\n| 1 | 2 |\n\nThe end."
        let picture = TrackerAttachment(blobRef: "b1", mime: "image/png", name: "one.png", size: 1)
        let rendered = render(content([.markdown(markdown), .attachment(picture), .markdown("After the picture.")]),
                              hosted: CGSize(width: 200, height: 120))
        let bodies = rendered.pieces.filter { if case .body = $0.kind { true } else { false } }
        XCTAssertEqual(bodies.count, 1)
        let (body, _) = try XCTUnwrap(body(of: rendered))
        XCTAssertEqual(body.body.blocks.count, 3)
        XCTAssertEqual(body.blockPieces.count, 3)
        let copied = body.body.copyText(in: NSRange(location: 0, length: body.body.text.length))
        XCTAssertTrue(copied.hasPrefix("0. A sentence"))
        XCTAssertTrue(copied.contains("7. A sentence"))
        XCTAssertTrue(copied.contains("let x = 1"))
        XCTAssertTrue(copied.contains("A\tB\n1\t2"))
        XCTAssertTrue(copied.hasSuffix("The end.\n\nAfter the picture."), copied)
        XCTAssertFalse(copied.contains("\u{FFFC}"))
        // The attachment's view is on its line, the card's full width to
        // draw in, as tall as it measured.
        let attachment = try XCTUnwrap(rendered.pieces.first { if case .hosted(.detail(.attachment)) = $0.kind { true } else { false } })
        XCTAssertEqual(attachment.frame.height, 120)
        XCTAssertEqual(attachment.frame.width, 368 - 2 * ItemTypography.cardPadding)
    }

    /// VoiceOver reads a table once, in place between the paragraphs
    /// around it, a row at a time; its links and Copy Table are actions on
    /// the card's text, and the table's own view stays hidden.
    @MainActor
    func test_theCardsTextReadsATableInPlace_withItsLinksAndCopyAsActions() throws {
        let markdown = "Before the table.\n\n| Col | Other |\n|---|---|\n| TABLECELL | [the docs](https://example.com/docs) |"
            + "\n\n```\nlet code = 1\n```\n\nAfter."
        let rendered = render(content([.markdown(markdown)]))
        let (body, _) = try XCTUnwrap(body(of: rendered))
        let cell = ItemTextCell(frame: CGRect(x: 0, y: 0, width: 320, height: 400))
        cell.configure(body: body, router: TimelineLinkRouter())
        let view = cell.textViewForTesting
        let spoken = try XCTUnwrap(view.accessibilityValue)
        let order = ["Before the table.", "Col, Other", "TABLECELL, the docs", "let code = 1", "After."]
            .map { (spoken as NSString).range(of: $0).location }
        XCTAssertFalse(order.contains(NSNotFound), spoken)
        XCTAssertEqual(order, order.sorted(), "read out of order: \(spoken)")
        let actions = view.accessibilityCustomActions?.map(\.name) ?? []
        XCTAssertTrue(actions.contains("Copy Table"), "\(actions)")
        XCTAssertTrue(actions.contains("Open the docs"), "\(actions)")
        let table = ItemTableCell(frame: .zero)
        XCTAssertTrue(table.contentView.subviews.allSatisfy { $0.accessibilityElementsHidden })
    }

    /// A card of prose alone hugs its text.
    func test_aShortCardsBody_hugsItsText() throws {
        let rendered = render(content([.markdown("ok")]))
        let (body, frame) = try XCTUnwrap(body(of: rendered))
        XCTAssertTrue(body.body.blocks.isEmpty)
        XCTAssertLessThan(frame.width, 100)
    }

    // MARK: Tables

    private func table(_ markdown: String) throws -> ItemTableLayout {
        for segment in MarkdownAttributed.rendered(for: markdown, style: style.markdown, cache: false).segments {
            if case .table(let table) = segment { return ItemTableLayout(table: table) }
        }
        throw XCTSkip("no table parsed")
    }

    func test_aTableConfiguredAgainWithItself_staysScrolledSideways() throws {
        let markdown = "| A | B | C |\n|---|---|---|\n| \(String(repeating: "wide ", count: 12)) | \(String(repeating: "wide ", count: 12)) | x |"
        let view = ItemTableView(frame: CGRect(x: 0, y: 0, width: 200, height: 80))
        view.configure(try table(markdown))
        view.scrollViewForTesting.contentOffset.x = 120
        view.configure(try table(markdown))
        XCTAssertEqual(view.scrollViewForTesting.contentOffset.x, 120, "the thread refreshing does not move a table")
        view.configure(try table("| A |\n|---|\n| other |"))
        XCTAssertEqual(view.scrollViewForTesting.contentOffset.x, 0, "another table starts at its leading edge")
    }

    func test_voiceOverReadsATableARowAtATime_andStopsOnEachLink() throws {
        let view = ItemTableView(frame: CGRect(x: 0, y: 0, width: 320, height: 120))
        let layout = try table("| Name | Where |\n|---|---|\n| Queue | see [the notes](https://example.com/notes) and [the plan](https://example.com/plan) |\n| Cache | none |")
        view.configure(layout)
        var opened: [URL] = []
        view.onOpenLink = { opened.append($0) }
        let elements = view.accessibilityElementsForTesting.compactMap { $0 as? UIAccessibilityElement }
        XCTAssertEqual(elements.map(\.accessibilityLabel),
                       ["Name, Where", "Queue, see the notes and the plan", "the notes", "the plan", "Cache, none"])
        XCTAssertTrue(elements[0].accessibilityTraits.contains(.header))
        XCTAssertEqual(elements[2].accessibilityTraits, .link)
        XCTAssertTrue(elements[3].accessibilityActivate())
        XCTAssertEqual(opened, [URL(string: "https://example.com/plan")!])
        // A link's box is inside its cell, the second after the first.
        let cell = layout.cellFrame(row: 1, column: 1)
        XCTAssertTrue(cell.contains(elements[2].accessibilityFrameInContainerSpace))
        XCTAssertTrue(cell.contains(elements[3].accessibilityFrameInContainerSpace))
        XCTAssertGreaterThan(elements[3].accessibilityFrameInContainerSpace.minX,
                             elements[2].accessibilityFrameInContainerSpace.maxX)
        XCTAssertFalse(view.isAccessibilityElement, "the table is read by its rows")
        XCTAssertEqual(elements[1].accessibilityCustomActions?.map(\.name), ["Copy Table"])
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

    func test_aTableAsText_isARowALine_cellsTabSeparated() throws {
        let layout = try table("| Part | Price |\n|---|---:|\n| **CPU** | 499 |\n| `RAM` | |")
        XCTAssertEqual(layout.plainText, "Part\tPrice\nCPU\t499\nRAM\t")
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
}

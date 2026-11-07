import XCTest
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

/// One text view per text row (`TextRowBody`): selection runs through code
/// blocks, the block views sit exactly on their placeholder lines, presses
/// off the text go to the row, and a copy carries the block text.
@MainActor
final class TimelineBodyTextViewTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)
    private var windows: [UIWindow] = []

    private func cell(_ body: String, width: CGFloat = 393) -> TextMessageCell {
        let factory = HostedRowFactory(viewModel: TimelineFixtures.viewModel(LiveTimelineFixture()), actions: .inert,
                                       environment: TimelineHostedEnvironment())
        let content = TextRowContent(itemID: "1", body: body, isOwn: false, sendState: .sent,
                                     timestamp: TimelineFixtures.base, avatarSender: nil, senderLabel: "matron",
                                     pills: [])
        guard case .text(let render) = TimelineMeasurer(factory: factory).measure(.text(content), width: width,
                                                                                  style: style) else {
            fatalError("text rows measure as renders")
        }
        let cell = TextMessageCell(frame: CGRect(x: 0, y: 0, width: width, height: render.layout.rowHeight))
        let window = UIWindow(frame: cell.frame)
        window.isHidden = false
        window.addSubview(cell)
        windows.append(window)
        cell.configure(render: render, factory: factory, onRetry: { _ in })
        cell.layoutIfNeeded()
        return cell
    }

    private let codeMessage = "Before the code, a paragraph.\n\n```swift\nlet queue = UploadQueue()\nqueue.start()\n```\n\nAfter."

    func test_aMessageWithCode_isOneTextView_withThePlaceholderOnTheCodeLine() throws {
        let cell = cell(codeMessage)
        let body = cell.bodyViewForTesting
        XCTAssertNotNil(body.textLayoutManager, "TextKit 2, as measured")
        XCTAssertEqual(body.attributedText.string, "Before the code, a paragraph.\n\u{FFFC}\nAfter.")
        XCTAssertEqual(body.accessibilityValue,
                       "Before the code, a paragraph.\nlet queue = UploadQueue()\nqueue.start()\nAfter.",
                       "VoiceOver reads the code where it sits")
        let code = try XCTUnwrap(cell.segmentViewsForTesting[1] as? CodeBlockSegmentView)
        XCTAssertTrue(cell.segmentViewsForTesting[0] === body)
        XCTAssertTrue(cell.segmentViewsForTesting[2] === body)
        // The block view sits where the live text view laid the placeholder.
        let manager = try XCTUnwrap(body.textLayoutManager)
        let start = try XCTUnwrap(manager.location(manager.documentRange.location, offsetBy: 30))
        let range = try XCTUnwrap(NSTextRange(location: start, end: manager.location(start, offsetBy: 1)))
        var line = CGRect.null
        manager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            line = line.union(frame)
            return true
        }
        let codeInBody = body.convert(code.bounds, from: code)
        XCTAssertEqual(line.minY, codeInBody.minY, accuracy: 0.5)
        XCTAssertEqual(line.height, codeInBody.height, accuracy: 0.5)
        // The text view covers the whole text.
        let used = try XCTUnwrap(body.textLayoutManager?.usageBoundsForTextContainer)
        XCTAssertGreaterThanOrEqual(body.bounds.height + 0.5, used.maxY, "\(body.frame) \(used)")
        // Under the text view, so the selection highlight covers it.
        let subviews = cell.bubbleForTesting.subviews
        XCTAssertLessThan(try XCTUnwrap(subviews.firstIndex(of: code)), try XCTUnwrap(subviews.firstIndex(of: body)))
    }

    func test_copyingASelectionThroughCode_putsTheCodeInThePlaceholdersPlace() {
        let body = cell(codeMessage).bodyViewForTesting
        XCTAssertTrue(body.becomeFirstResponder())
        body.selectedRange = NSRange(location: 7, length: body.attributedText.length - 7)
        body.copy(nil)
        XCTAssertEqual(UIPasteboard.general.string,
                       "the code, a paragraph.\nlet queue = UploadQueue()\nqueue.start()\nAfter.")
    }

    func test_copyText_ofATable_isTabSeparatedRows() {
        let table = MarkdownTable(columnCount: 2, alignments: [.left, .left],
                                  rows: [[NSAttributedString(string: "a"), NSAttributedString(string: "b")],
                                         [NSAttributedString(string: "1"), NSAttributedString(string: "2")]])
        let body = TextRowBody.build([.text(NSAttributedString(string: "Intro")), .table(table)],
                                     blockHeights: [1: 40], width: 300, spacing: 8, font: .systemFont(ofSize: 17))
        XCTAssertEqual(body.copyText(in: NSRange(location: 0, length: body.text.length)), "Intro\na\tb\n1\t2")
    }

    func test_proseOnly_isTheSegmentStringItself() throws {
        let cell = cell("Just one paragraph.")
        guard case .text(let text)? = cell.render?.segments.first else { return XCTFail() }
        XCTAssertTrue(cell.render?.body.text === text, "prose-only rows keep the memoised string")
        XCTAssertEqual(cell.bodyViewForTesting.frame, cell.render?.layout.segmentFrames.first)
    }

    func test_pressesOnText_belongToTheTextView_otherPressesToTheRow() throws {
        let cell = cell("Short line\n\nA second paragraph that wraps over a couple of lines on a phone screen.")
        let body = cell.bodyViewForTesting
        let manager = try XCTUnwrap(body.textLayoutManager)
        var firstLine = CGRect.null
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) {
            fragment in
            if let line = fragment.textLineFragments.first {
                firstLine = line.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                            dy: fragment.layoutFragmentFrame.minY)
            }
            return false
        }
        let onWord = CGPoint(x: 10, y: firstLine.midY)
        let pastLineEnd = CGPoint(x: body.bounds.maxX - 10, y: firstLine.midY)
        XCTAssertTrue(body.point(inside: onWord, with: nil))
        XCTAssertFalse(body.point(inside: pastLineEnd, with: nil), "blank space past a short line is the row's")
        XCTAssertTrue(cell.isTextHit(body.convert(onWord, to: cell)))
        XCTAssertFalse(cell.isTextHit(body.convert(pastLineEnd, to: cell)))
        XCTAssertFalse(cell.isTextHit(CGPoint(x: 2, y: 2)), "the bubble's padding")
    }

    func test_pressesOnACodeBlock_goToTheCodeBlock() throws {
        let cell = cell(codeMessage)
        let code = try XCTUnwrap(cell.segmentViewsForTesting[1] as? CodeBlockSegmentView)
        let middle = CGPoint(x: code.bounds.midX, y: code.bounds.maxY - 12)
        XCTAssertFalse(cell.bodyViewForTesting.point(inside: cell.bodyViewForTesting.convert(middle, from: code),
                                                     with: nil))
        let hit = cell.hitTest(cell.convert(middle, from: code), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: code) == true, "hit \(String(describing: hit))")
    }

    func test_aPressOnAnEmoji_isOnTheText() throws {
        let body = cell("🎉 Shipped it").bodyViewForTesting
        let start = body.beginningOfDocument
        let end = try XCTUnwrap(body.position(from: start, offset: 2))
        let emoji = body.firstRect(for: try XCTUnwrap(body.textRange(from: start, to: end)))
        XCTAssertTrue(body.isOnText(CGPoint(x: emoji.minX + 2, y: emoji.midY)), "left half of the emoji")
        XCTAssertTrue(body.isOnText(CGPoint(x: emoji.maxX - 2, y: emoji.midY)), "right half of the emoji")
    }

    func test_theSeparator_carriesNoLinkOrAttachment() {
        let link = NSAttributedString(string: "See docs", attributes: [.link: URL(string: "https://example.com")!])
        let body = TextRowBody.build([.text(link), .code(language: nil, code: "x"), .text(NSAttributedString(string: "End"))],
                                     blockHeights: [1: 40], width: 300, spacing: 8, font: .systemFont(ofSize: 17))
        let afterLink = body.text.attributes(at: 8, effectiveRange: nil)
        XCTAssertNil(afterLink[.link], "the link stops at its own text")
        let afterBlock = body.text.attributes(at: 10, effectiveRange: nil)
        XCTAssertNil(afterBlock[.attachment], "the placeholder is one character")
    }

    func test_blockViews_areHiddenFromVoiceOver_theCopyButtonIsNot() throws {
        let cell = cell(codeMessage)
        let code = try XCTUnwrap(cell.segmentViewsForTesting[1] as? CodeBlockSegmentView)
        XCTAssertFalse(code.codeTextView.isAccessibilityElement, "the body reads the code once, in place")
        XCTAssertTrue(code.codeTextView.accessibilityElementsHidden)
        XCTAssertTrue(code.copyButtonForTesting.isAccessibilityElement || code.copyButtonForTesting.accessibilityLabel != nil)
        XCTAssertFalse(code.copyButtonForTesting.accessibilityElementsHidden)
    }

    func test_aSelectionEndingAtACodeBlock_leavesItsCopyButtonPressable() throws {
        let cell = cell(codeMessage)
        let body = cell.bodyViewForTesting
        let code = try XCTUnwrap(cell.segmentViewsForTesting[1] as? CodeBlockSegmentView)
        XCTAssertTrue(body.becomeFirstResponder())
        // From the start through the placeholder: the end caret is at the
        // right edge of the code block's line, as tall as the block.
        body.selectedRange = NSRange(location: 0, length: 31)
        let button = code.copyButtonForTesting
        let hit = cell.hitTest(cell.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), from: button), with: nil)
        XCTAssertTrue(hit?.isDescendant(of: code) == true, "hit \(String(describing: hit))")
        // The end handle's knob, below the block, is still the text view's.
        let end = body.caretRect(for: try XCTUnwrap(body.selectedTextRange).end)
        XCTAssertTrue(body.point(inside: CGPoint(x: end.midX - 4, y: end.maxY + 4), with: nil))
    }
}

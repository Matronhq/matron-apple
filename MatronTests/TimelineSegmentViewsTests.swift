import XCTest
import SwiftUI
import UIKit
import MatronDesignSystem
@testable import Matron

@MainActor
final class TimelineSegmentViewsTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)

    func test_codeBlockView_layoutMatchesItsMetrics() {
        let code = "let x = 1\nlet y = 2"
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: code, style: style)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: CodeBlockMetrics.height(code: code, style: style))
        view.layoutIfNeeded()
        XCTAssertEqual(view.codeScrollFrame.height,
                       CodeBlockMetrics.codeSize(code, style: style).height + 2 * CodeBlockMetrics.codePadding)
        XCTAssertEqual(view.codeScrollFrame.maxY, view.bounds.height)
    }

    func test_codeBlockView_layoutMatchesItsMetrics_emptyFence() {
        let code = ""
        let view = CodeBlockSegmentView()
        view.configure(language: nil, code: code, style: style)
        view.frame = CGRect(x: 0, y: 0, width: 300, height: CodeBlockMetrics.height(code: code, style: style))
        view.layoutIfNeeded()
        XCTAssertEqual(view.codeScrollFrame.height,
                       CodeBlockMetrics.codeSize(code, style: style).height + 2 * CodeBlockMetrics.codePadding)
        XCTAssertEqual(view.codeScrollFrame.maxY, view.bounds.height)
    }

    /// Reconfiguring with the SAME code (a streaming row recomputes every
    /// frame) must not reassign `attributedText` — that would clear any
    /// selection the user made inside the code block mid-stream.
    func test_codeBlockView_reconfigureWithSameCode_preservesSelection() {
        let code = "let x = 1\nlet y = 2"
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: code, style: style)
        let textView = view.codeTextView
        textView.selectedTextRange = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument)

        view.configure(language: "swift", code: code, style: style)

        XCTAssertNotNil(textView.selectedTextRange, "an unchanged code string must not reset the text view's selection")
    }

    /// A Dynamic Type change re-measures with the SAME code but a different
    /// style — the code must still re-render at the new size (the style is
    /// part of the memoization key, not just the code string).
    func test_codeBlockView_reconfigureWithSameCode_differentStyle_stillRerenders() {
        let code = "let x = 1\nlet y = 2"
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: code, style: style)
        let smallHeight = view.codeTextView.attributedText.size().height

        let hugeStyle = TimelineTextStyle(sizeCategory: .accessibilityExtraExtraExtraLarge)
        view.configure(language: "swift", code: code, style: hugeStyle)
        let hugeHeight = view.codeTextView.attributedText.size().height

        XCTAssertNotEqual(smallHeight, hugeHeight,
                          "the code block must re-render at the new Dynamic Type size, even with unchanged code")
    }

    /// Selection inside a code block gets the same "Copy Message" edit-menu
    /// item as the prose text view — set through `messageBodyForEditMenu`,
    /// the owning cell's hook (`TextMessageCell` reads its own `render` the
    /// same way for its own text views).
    func test_codeBlockEditMenu_addsCopyMessage() {
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: "let x = 1", style: style)
        view.messageBodyForEditMenu = { "Run:\n\n```swift\nlet x = 1\n```" }
        let menu = view.textView(view.codeTextView, editMenuForTextIn: NSRange(location: 0, length: 3),
                                 suggestedActions: [])
        XCTAssertEqual(menu?.children.compactMap { ($0 as? UIAction)?.title }, ["Copy Message"])
    }

    func test_codeBlockEditMenu_nilWithoutAMessageBodyHook() {
        let view = CodeBlockSegmentView()
        view.configure(language: "swift", code: "let x = 1", style: style)
        let menu = view.textView(view.codeTextView, editMenuForTextIn: NSRange(location: 0, length: 3),
                                 suggestedActions: [])
        XCTAssertNil(menu)
    }

    func test_codeBlockCopy_copiesTheBareCode() {
        let view = CodeBlockSegmentView()
        view.configure(language: nil, code: "make test", style: style)
        view.copyCode()
        XCTAssertEqual(UIPasteboard.general.string, "make test")
    }

    func test_tableGridCellText_keepsBoldAndLinks() {
        let source = NSMutableAttributedString(string: "go ", attributes: [.font: UIFont.systemFont(ofSize: 17)])
        source.append(NSAttributedString(string: "here", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 17), .link: URL(string: "https://example.com")!]))
        let converted = MarkdownTableGrid.attributed(source)
        let runs = Array(converted.runs)
        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1].link, URL(string: "https://example.com"))
        XCTAssertEqual(String(converted.characters), "go here")
    }

    func test_sendStateView_labelsAndTappability() {
        let view = SendStateView()
        view.configure(state: .failed(reason: "offline"), font: style.timestampFont, onRetry: {})
        XCTAssertFalse(view.isHidden)
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertEqual(view.accessibilityLabel, "Send failed: offline. Tap to retry.")
        view.configure(state: .sending, font: style.timestampFont, onRetry: {})
        XCTAssertFalse(view.isUserInteractionEnabled)
        XCTAssertEqual(view.accessibilityLabel, "Sending")
        view.configure(state: .sent, font: style.timestampFont, onRetry: {})
        XCTAssertTrue(view.isHidden)
    }

    func test_avatarView_usesTheSharedInitials() {
        let view = SenderAvatarView()
        view.configure(name: "drop-2")
        XCTAssertEqual(view.text, SenderAvatar.initials(for: "drop-2"))
        XCTAssertFalse(view.isAccessibilityElement)
    }

    func test_snapshots_codeBlockAndTable() {
        let code = CodeBlockSegmentView()
        code.configure(language: "swift", code: "let queue = UploadQueue(maxRetries: 3)\nqueue.start()", style: style)
        assertTimelineSnapshot(code, size: CGSize(width: 300, height: CodeBlockMetrics.height(
            code: "let queue = UploadQueue(maxRetries: 3)\nqueue.start()", style: style)), named: "code-block")

        let table = MarkdownTable(columnCount: 2, alignments: [.left, .right], rows: [
            [NSAttributedString(string: "Case"), NSAttributedString(string: "Result")],
            [NSAttributedString(string: "retry"), NSAttributedString(string: "ok")],
        ])
        let host = UIHostingController(rootView: MarkdownTableGrid(table: table, router: TimelineLinkRouter()))
        assertTimelineSnapshot(host.view, size: CGSize(width: 300, height: 80), named: "table-grid")
    }
}

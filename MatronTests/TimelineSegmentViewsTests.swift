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
        view.configure(name: "dev-2")
        XCTAssertEqual(view.text, SenderAvatar.initials(for: "dev-2"))
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

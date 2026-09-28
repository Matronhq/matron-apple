import XCTest
import SwiftUI
import MatronChat
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineRowViewTests: XCTestCase {
    private func render(_ body: String, own: Bool = false, width: CGFloat = 700) -> MacTextRowRender {
        let content = TextRowContent(itemID: "m-\(body.hashValue)", body: body, isOwn: own, sendState: .sent,
                                     timestamp: Date(timeIntervalSince1970: 1_700_000_000), avatarSender: nil,
                                     senderLabel: "bot", pills: [])
        return MacTimelineMeasurer.measureText(content, width: width, pillsHeight: nil, sendStateHeight: nil)
    }

    private func row(_ r: MacTextRowRender, width: CGFloat = 700) -> MacTextRowView {
        let v = MacTextRowView(frame: NSRect(x: 0, y: 0, width: width, height: r.layout.rowHeight))
        v.configure(render: r, selectionController: nil, linkRouting: .init(),
                    pills: { nil }, sendState: { nil })
        v.layoutSubtreeIfNeeded()
        return v
    }

    func test_bubbleAndBodyFramesComeFromTheLayout() {
        let r = render("Hello there")
        let v = row(r)
        XCTAssertEqual(v.bubbleFrameForTesting, r.layout.bubbleFrame)
        XCTAssertEqual(v.body.frame, r.layout.segmentFrames[0].offsetBy(dx: r.layout.bubbleFrame.minX, dy: r.layout.bubbleFrame.minY))
    }

    func test_reuseDropsSelectionFlashAndCheckmark() {
        let v = row(render("First message with some words"))
        v.body.textView.setSelectedRange(NSRange(location: 0, length: 5))
        v.flash()
        v.prepareForReuse()
        v.configure(render: render("Second"), selectionController: nil, linkRouting: .init(),
                    pills: { nil }, sendState: { nil })
        XCTAssertEqual(v.body.textView.selectedRange().length, 0)
        XCTAssertFalse(v.hasFlashForTesting)
        XCTAssertEqual(v.body.textView.string, "Second")
    }

    /// Final review: the wash sits OVER the content — below it, the opaque
    /// bubble hid it — and never takes a click.
    func test_flashIsTheTopmostSubview() {
        let v = row(render("Jumped to"))
        v.flash()
        XCTAssertTrue(v.hasFlashForTesting)
        XCTAssertTrue(v.flashIsTopmostForTesting)
        let hit = v.hitTest(NSPoint(x: v.bubbleFrameForTesting.midX, y: v.bubbleFrameForTesting.midY))
        XCTAssertNotEqual(hit?.tag, TimelineRowFlash.tag)
    }

    func test_tabledMessagesUseTextKit1AndPlainUseTextKit2() {
        let plain = row(render("Plain"))
        XCTAssertNotNil(plain.body.textView.textLayoutManager)
        let tabled = row(render("| A |\n|---|\n| 1 |"))
        XCTAssertNil(tabled.body.textView.textLayoutManager)   // TK1 after the opt-out
    }
}

import XCTest
import SwiftUI
import MatronChat
import MatronDesignSystem
@testable import MatronMac

@MainActor final class MacTimelineRowViewTests: XCTestCase {
    private func render(_ body: String, own: Bool = false, width: CGFloat = 700,
                        itemID: String? = nil) -> MacTextRowRender {
        let content = TextRowContent(itemID: itemID ?? "m-\(body.hashValue)", body: body, isOwn: own, sendState: .sent,
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

    /// Review gap 7a: reuse also cancels a code-copy checkmark (after a real
    /// click) and takes the body out of the cross-message selection.
    func test_reuseResetsTheCodeCheckmarkAndUnregistersFromTheSelection() throws {
        let source = "Before\n\n```\nmake test\n```\n\nAfter"
        let r = render(source)
        let selection = MessageSelectionController()
        selection.orderedIDs = [r.content.itemID]
        let v = MacTextRowView(frame: NSRect(x: 0, y: 0, width: 700, height: r.layout.rowHeight))
        // A body registers with the selection only while in a window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.addSubview(v)
        v.configure(render: r, selectionController: selection, linkRouting: .init(), pills: { nil }, sendState: { nil })
        v.layoutSubtreeIfNeeded()

        let button = try XCTUnwrap(v.body.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)
        // The button copies to the general pasteboard: put back everything
        // the developer had on it, every item in every flavour.
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { flavours in
                let item = NSPasteboardItem()
                for (type, data) in flavours { item.setData(data, forType: type) }
                return item
            })
        }
        button.performClick(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "make test")
        XCTAssertEqual(button.contentTintColor, .systemGreen)          // the checkmark

        // Registered: the live body answers for its row (an empty span, "").
        XCTAssertTrue(selection.beginCrossMessage(anchorID: r.content.itemID, charIndex: 0))
        XCTAssertEqual(selection.selectedSpans().first?.text, "")

        v.prepareForReuse()
        XCTAssertEqual(button.contentTintColor, .secondaryLabelColor)  // checkmark cancelled
        // Unregistered: no live target and no provider → no text for the row.
        XCTAssertEqual(selection.selectedSpans().map(\.id), [r.content.itemID])
        XCTAssertNil(selection.selectedSpans().first?.text)
    }

    /// Perf follow-ups S3: a streaming (`eph:`) body gets no code-copy
    /// buttons; the same body as a finished message gets one per block, also
    /// when the streaming row's view is reused for it.
    func test_streamingRowHasNoCodeButtonsAndAFinishedMessageHasThem() {
        let source = "Before\n\n```\nmake test\n```\n\nBetween\n\n```\nswift build\n```\n\nAfter"
        func buttons(_ v: MacTextRowView) -> Int { v.body.subviews.filter { $0 is NSButton }.count }

        let streaming = row(render(source, itemID: "eph:r"))
        XCTAssertEqual(buttons(streaming), 0)

        let finishedRender = render(source, itemID: "$final")
        XCTAssertEqual(finishedRender.rendered.codeBlockFrames(width: finishedRender.layout.segmentFrames[0].width).count, 2)
        XCTAssertEqual(buttons(row(finishedRender)), 2)

        // Reuse: the streaming row's view now shows the finished message.
        streaming.prepareForReuse()
        streaming.frame.size.height = finishedRender.layout.rowHeight
        streaming.configure(render: finishedRender, selectionController: nil, linkRouting: .init(),
                            pills: { nil }, sendState: { nil })
        streaming.layoutSubtreeIfNeeded()
        XCTAssertEqual(buttons(streaming), 2)

        // And back: a view showing buttons drops them for a streaming body.
        streaming.prepareForReuse()
        streaming.configure(render: render(source, itemID: "eph:s"), selectionController: nil, linkRouting: .init(),
                            pills: { nil }, sendState: { nil })
        streaming.layoutSubtreeIfNeeded()
        XCTAssertEqual(buttons(streaming), 0)
    }

    /// Wave M item 6: the bubble's layer shadow has an explicit path (no
    /// offscreen alpha pass per bubble while scrolling) that follows the
    /// bubble's frame — and the shadow really draws (it never did: AppKit
    /// zeroed the layer-only shadow's opacity).
    func test_bubbleShadowHasAPathMatchingTheBubbleAndStillDraws() throws {
        let r = render("A message with a shadow under its bubble")
        let v = row(r)
        let path = try XCTUnwrap(v.bubbleShadowPathForTesting)
        XCTAssertEqual(path.boundingBoxOfPath, CGRect(origin: .zero, size: r.layout.bubbleFrame.size))

        // Re-laid out at another width: the path follows the new frame.
        let wide = render("A message with a shadow under its bubble", width: 1100)
        v.frame.size.width = 1100
        v.configure(render: wide, selectionController: nil, linkRouting: .init(), pills: { nil }, sendState: { nil })
        v.layoutSubtreeIfNeeded()
        XCTAssertEqual(v.bubbleShadowPathForTesting?.boundingBoxOfPath,
                       CGRect(origin: .zero, size: wide.layout.bubbleFrame.size))

        // In a window (the layer's display pass runs): the shadow is really
        // on — AppKit resets layer-only shadow properties, so this read 0
        // opacity before the fix — and the explicit path survives AppKit
        // applying `NSView.shadow`. (Not checked as pixels: in the test host
        // `cacheDisplay` draws no layer shadows and `CALayer.render(in:)`
        // draws none of this AppKit layer tree.)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 200), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView?.wantsLayer = true
        window.contentView?.addSubview(v)
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        v.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        // The layer's display (updateLayer) runs at the transaction commit.
        XCTAssertEqual(v.bubbleCornerRadiusForTesting, 8)
        XCTAssertEqual(v.bubbleShadowOpacityForTesting, 1)
        XCTAssertEqual(v.bubbleShadowRadiusForTesting, 1)                     // `MessageBubble`: radius 1,
        XCTAssertEqual(v.bubbleShadowOffsetForTesting, CGSize(width: 0, height: -1))  // 1 pt down
        XCTAssertNotNil(v.bubbleShadowColorForTesting)
        XCTAssertEqual(v.bubbleShadowPathForTesting?.boundingBoxOfPath,
                       CGRect(origin: .zero, size: wide.layout.bubbleFrame.size))
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

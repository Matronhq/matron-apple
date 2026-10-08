import XCTest
import UIKit
import MatronModels
import MatronDesignSystem
@testable import Matron

final class TextRowRendererTests: XCTestCase {
    private let style = TimelineTextStyle(sizeCategory: .large)
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func content(_ body: String, own: Bool = false, state: TimelineSendState = .sent,
                         pills: [ConversationLinkRef] = []) -> TextRowContent {
        TextRowContent(itemID: "1", body: body, isOwn: own, sendState: state, timestamp: t0,
                       avatarSender: nil, senderLabel: own ? "Me" : "matron", pills: pills)
    }

    private func wrap(_ render: TextRowRender) -> CGFloat {
        TextBubbleGeometry.wrapWidth(rowWidth: 393, isOwn: render.content.isOwn, hasAvatar: false,
                                     timestampWidth: render.layout.timestampFrame.width)
    }

    func test_plainRow_layoutMatchesItsParts() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("Hello there"), width: 393, style: style))
        XCTAssertEqual(render.segments.count, 1)
        XCTAssertEqual(render.layout.bubbleFrame.minX, 16)
        XCTAssertEqual(render.layout.rowHeight, render.layout.bubbleFrame.height)
        guard case .text(let text) = render.segments[0] else { return XCTFail() }
        XCTAssertEqual(render.layout.segmentFrames[0].height, TextKitMeasure.hugging(text, width: wrap(render)).size.height)
    }

    func test_ownSendingRow_addsTheSendStateLine() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("On my way", own: true, state: .sending),
                                                                    width: 393, style: style))
        let sendState = try XCTUnwrap(render.layout.sendStateFrame)
        XCTAssertEqual(render.layout.rowHeight, ceil(sendState.maxY))
    }

    func test_codeBlock_takesTheFullWrapWidth_andItsOwnHeight() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(
            content("Run this:\n\n```sh\nmake test\n```"), width: 393, style: style))
        XCTAssertEqual(render.segments.count, 2)
        XCTAssertEqual(render.layout.segmentFrames[1].width, wrap(render))
        XCTAssertEqual(render.layout.segmentFrames[1].height, CodeBlockMetrics.height(code: "make test", style: style))
    }

    func test_backgroundRender_refusesRowsThatNeedHosting() {
        XCTAssertNil(TextRowRenderer.backgroundRender(content("| a |\n|---|\n| 1 |"), width: 393, style: style))
        XCTAssertNil(TextRowRenderer.backgroundRender(
            content("see [x](matron://convo/x)", pills: [ConversationLinkRef(id: "x", text: "x")]), width: 393, style: style))
        XCTAssertNotNil(TextRowRenderer.backgroundRender(content("plain"), width: 393, style: style))
    }

    func test_render_usesTheHostedPiecesHeights() {
        let render = TextRowRenderer.render(content("Table:\n\n| a |\n|---|\n| 1 |"), width: 393, style: style) { piece, _ in
            if case .table = piece { return 77 }
            return 0
        }
        XCTAssertEqual(render.layout.segmentFrames.last?.height, 77)
    }

    func test_emptyBody_rendersATimestampOnlyBubble() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content(""), width: 393, style: style))
        XCTAssertTrue(render.segments.isEmpty)
        XCTAssertGreaterThan(render.layout.rowHeight, 0)
        XCTAssertEqual(render.layout.bubbleFrame.width, 24 + 6 + render.layout.timestampFrame.width)
    }

    func test_unbrokenToken_wrapsInsideTheBubble() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content(String(repeating: "a", count: 500)),
                                                                    width: 393, style: style))
        XCTAssertLessThanOrEqual(render.layout.segmentFrames[0].width, wrap(render))
        XCTAssertLessThanOrEqual(render.layout.bubbleFrame.maxX, 393 - 16)
        XCTAssertGreaterThan(render.layout.segmentFrames[0].height, 17 * 3)
    }

    func test_timestampText_matchesTheSwiftUIFormat() throws {
        let render = try XCTUnwrap(TextRowRenderer.backgroundRender(content("x"), width: 393, style: style))
        XCTAssertEqual(render.timestampText, t0.formatted(.dateTime.hour().minute()))
    }
}

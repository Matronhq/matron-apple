import XCTest
@testable import Matron

/// Mirrors `MessageBubble` + `TimelineItemView`'s own-row VStack exactly.
final class TextBubbleGeometryTests: XCTestCase {
    private let stamp = TextBubbleGeometry.Timestamp(size: CGSize(width: 30, height: 13), ascent: 10)
    private var wraps: [CGFloat] = []

    private func content(_ size: CGSize = CGSize(width: 100, height: 20), baseline: CGFloat = 16)
        -> (CGFloat) -> TextBubbleGeometry.Content {
        { wrap in
            self.wraps.append(wrap)
            return .init(size: size, lastBaseline: baseline, segmentFrames: [CGRect(origin: .zero, size: size)])
        }
    }

    private func layout(width: CGFloat = 393, own: Bool = false, avatar: Bool = false,
                        pills: ((CGFloat) -> CGFloat)? = nil, sendState: CGFloat? = nil,
                        size: CGSize = CGSize(width: 100, height: 20), baseline: CGFloat = 16) -> TextRowLayout {
        TextBubbleGeometry.layout(rowWidth: width, isOwn: own, hasAvatar: avatar, timestamp: stamp,
                                  content: content(size, baseline: baseline), pillsHeight: pills,
                                  sendStateHeight: sendState)
    }

    func test_botBubble_hugsItsContent_atTheLeadingEdge() {
        let result = layout()
        XCTAssertEqual(wraps, [CGFloat(361 - 24 - 6 - 30)])
        XCTAssertEqual(result.bubbleFrame, CGRect(x: 16, y: 0, width: 160, height: 36))
        XCTAssertEqual(result.segmentFrames, [CGRect(x: 12, y: 8, width: 100, height: 20)])
        XCTAssertEqual(result.timestampFrame, CGRect(x: 118, y: 14, width: 30, height: 13))
        XCTAssertEqual(result.rowHeight, 36)
        XCTAssertNil(result.avatarFrame)
    }

    func test_ownBubble_sitsAtTheTrailingEdge_withTheOwnInset() {
        let result = layout(own: true)
        XCTAssertEqual(wraps, [CGFloat(361 - 32 - 60)])
        XCTAssertEqual(result.bubbleFrame.maxX, 393 - 16)
    }

    func test_avatar_indentsTheBubble_andBottomAligns() {
        let result = layout(avatar: true)
        XCTAssertEqual(wraps, [CGFloat(361 - 30 - 60)])
        XCTAssertEqual(result.bubbleFrame.minX, 46)
        XCTAssertEqual(result.avatarFrame, CGRect(x: 16, y: 12, width: 24, height: 24))
    }

    func test_ownRows_neverGetAnAvatar() {
        let result = layout(own: true, avatar: true)
        XCTAssertNil(result.avatarFrame)
        XCTAssertEqual(wraps, [CGFloat(361 - 32 - 60)])
    }

    func test_timestampTallerThanTheContentBaseline_liftsTheContent() {
        let result = layout(size: CGSize(width: 100, height: 8), baseline: 5)
        XCTAssertEqual(result.segmentFrames[0].minY, 8 + 5)
        XCTAssertEqual(result.timestampFrame.minY, 8)
        XCTAssertEqual(result.bubbleFrame.height, 16 + 13)
    }

    func test_pillsAndSendState_stackUnderTheBubble() {
        let result = layout(own: true, pills: { _ in 30 }, sendState: 14)
        XCTAssertEqual(result.pillsFrame, CGRect(x: 0, y: 40, width: 393, height: 30))
        XCTAssertEqual(result.sendStateFrame, CGRect(x: 16, y: 72, width: 361, height: 14))
        XCTAssertEqual(result.rowHeight, 86)
    }

    func test_wideWindow_capsTheBubbleAt760() {
        _ = layout(width: 1200)
        XCTAssertEqual(wraps, [CGFloat(760 - 60)])
    }
}

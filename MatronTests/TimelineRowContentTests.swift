import XCTest
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import Matron

final class TimelineRowContentTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func text(_ id: String, _ body: String, own: Bool = false, sender: String = "matron",
                      state: TimelineSendState = .sent) -> TimelineRow {
        .message(TimelineItem(id: id, sender: sender, timestamp: t0, kind: .text(body: body, formattedHTML: nil),
                              isOwn: own, sendState: state))
    }

    private func build(_ rows: [TimelineRow], multi: Bool = false, children: [SubChatSummary] = [],
                       pixel: CGSize? = nil) -> BuiltRows {
        TimelineRowContentBuilder.build(TimelineRowSource(
            rows: rows, hasMultipleSenders: multi, children: children, imagePixelSize: { _ in pixel }))
    }

    func test_anchorIDs_useItemIDsForMessages_andRowIDsForSeparators() {
        XCTAssertEqual(TimelineRowContentBuilder.anchorID(for: text("42", "hi")), "42")
        let separator = TimelineRow.separator(date: t0)
        XCTAssertEqual(TimelineRowContentBuilder.anchorID(for: separator), separator.id)
        XCTAssertTrue(separator.id.hasPrefix("sep:"))
    }

    func test_textMessages_becomeTextRows_everythingElseHosted() {
        let image = TimelineRow.message(TimelineItem(id: "7", sender: "matron", timestamp: t0,
            kind: .image(url: URL(string: "mxc://s/a"), caption: nil, sizeBytes: nil, expired: false), isOwn: false))
        let built = build([.separator(date: t0), text("1", "hello"), image], pixel: CGSize(width: 800, height: 600))
        XCTAssertEqual(built.contents.map(\.anchorID), [TimelineRow.separator(date: t0).id, "1", "7"])
        guard case .hosted = built.contents[0], case .text(let row) = built.contents[1],
              case .hosted(let hosted) = built.contents[2] else { return XCTFail("\(built.contents)") }
        XCTAssertEqual(row.body, "hello")
        XCTAssertEqual(row.senderLabel, "matron")
        XCTAssertEqual(hosted.imagePixelSize, CGSize(width: 800, height: 600),
                       "an image row's resolution is part of its content — resolving re-measures only that row")
    }

    func test_ownRow_carriesSendStateAndMeLabel_andNoAvatar() {
        let built = build([text("1", "sending…", own: true, sender: "@dan:s", state: .sending)], multi: true)
        guard case .text(let row) = built.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.sendState, .sending)
        XCTAssertEqual(row.senderLabel, "Me")
        XCTAssertNil(row.avatarSender)
    }

    func test_multiSenderRoom_givesBotRowsAnAvatar_exceptTheStreamingPlaceholder() {
        let built = build([text("1", "a", sender: "dev-2"), text("eph:r", "streaming", sender: "agent")], multi: true)
        guard case .text(let real) = built.contents[0], case .text(let streaming) = built.contents[1] else { return XCTFail() }
        XCTAssertEqual(real.avatarSender, "dev-2")
        XCTAssertNil(streaming.avatarSender)
        XCTAssertTrue(streaming.isStreaming)
    }

    func test_conversationLinks_becomePills() {
        let built = build([text("1", "See [Auth](matron://convo/auth-1) and [Dark](matron://convo/dark-2).")])
        guard case .text(let row) = built.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.pills.map(\.id), ["auth-1", "dark-2"])
    }

    func test_subtaskIndicator_withAMatchingChild_isHosted() throws {
        let body = "🔀 Subtask: Explore auth call sites"
        let description = try XCTUnwrap(SubChatStripViewModel.subtaskDescription(fromMessageBody: body))
        let child = SubChatSummary(id: "child-1", title: description, isRunning: true)
        let built = build([text("1", body)], children: [child])
        guard case .hosted(let hosted) = built.contents[0] else { return XCTFail("\(built.contents)") }
        XCTAssertEqual(hosted.subtaskChild?.id, "child-1")
    }

    func test_duplicateAnchorIDs_areDroppedAfterTheFirst() {
        let built = build([text("1", "first"), text("2", "two"), text("1", "again")])
        XCTAssertEqual(built.contents.map(\.anchorID), ["1", "2"])
        XCTAssertEqual(built.droppedDuplicates, ["1"])
    }
}

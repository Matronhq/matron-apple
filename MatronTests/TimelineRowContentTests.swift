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
                       pixel: CGSize? = nil, titles: [String: ConversationLinkTitle] = [:]) -> BuiltRows {
        TimelineRowContentBuilder.build(TimelineRowSource(
            rows: rows, hasMultipleSenders: multi, children: children, imagePixelSize: { _ in pixel },
            pillTitle: { titles[$0] }))
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

    /// Tracker #3944: what a pill draws is part of the row's content, so a
    /// title loading misses the measurement cache and re-measures the row.
    func test_pillLabels_followTheConversationTitles() {
        let row = text("1", "See [Auth](matron://convo/auth-1) and [Dark](matron://convo/dark-2).")
        let before = build([row])
        let after = build([row], titles: ["auth-1": .known("Auth refactor: split the token store"),
                                          "dark-2": .unknown])
        guard case .text(let unloaded) = before.contents[0], case .text(let loaded) = after.contents[0] else {
            return XCTFail()
        }
        XCTAssertEqual(unloaded.pillLabels, ["Auth", "Dark"])
        XCTAssertEqual(loaded.pillLabels, ["Auth refactor: split the token store", "Dark"])
        XCTAssertNotEqual(before.contents[0], after.contents[0])
    }

    /// Only the pills on show are drawn; the rest sit behind "+N", whose
    /// label does not depend on any title.
    func test_pillLabels_coverOnlyThePillsOnShow() {
        let links = (1...6).map { "[c\($0)](matron://convo/c\($0))" }.joined(separator: " ")
        let built = build([text("1", links)], titles: ["c6": .known("A long title behind the overflow")])
        guard case .text(let row) = built.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.pills.count, 6)
        XCTAssertEqual(row.pillLabels, ["c1", "c2", "c3", "c4"])
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

    // MARK: Reuse across builds (tracker #3536)

    private func build(_ rows: [TimelineRow], memo: TimelineRowScanMemo,
                       children: [SubChatSummary] = []) -> BuiltRows {
        TimelineRowContentBuilder.build(TimelineRowSource(
            rows: rows, hasMultipleSenders: false, children: children, imagePixelSize: { _ in nil }), memo: memo)
    }

    private func window(streaming: String) -> [TimelineRow] {
        (0..<50).map { text("\($0)", "message \($0) see [c](matron://convo/c\($0))") }
            + [text("eph:1", streaming)]
    }

    func test_memo_streamingCommit_rescansOnlyTheStreamingRow() {
        let memo = TimelineRowScanMemo()
        let first = build(window(streaming: "Hel"), memo: memo)
        XCTAssertEqual(memo.lastScanCount, 51)
        let second = build(window(streaming: "Hello"), memo: memo)
        XCTAssertEqual(memo.lastScanCount, 1, "only the streaming row changed")
        guard case .text(let reused) = second.contents[3] else { return XCTFail() }
        XCTAssertEqual(reused.pills.map(\.id), ["c3"], "a reused row keeps its pills")
        XCTAssertEqual(Array(second.contents.prefix(50)), Array(first.contents.prefix(50)))
        XCTAssertEqual(second.contents, build(window(streaming: "Hello")).contents,
                       "reused output matches a fresh build")
    }

    func test_memo_editedBodyOrOwnership_isRescanned() {
        let memo = TimelineRowScanMemo()
        _ = build([text("1", "a"), text("2", "b")], memo: memo)
        let edited = build([text("1", "a [X](matron://convo/x)"), text("2", "b", own: true)], memo: memo)
        XCTAssertEqual(memo.lastScanCount, 2)
        guard case .text(let row) = edited.contents[0] else { return XCTFail() }
        XCTAssertEqual(row.pills.map(\.id), ["x"])
    }

    func test_memo_childrenChange_rescansEverything_andResolvesTheIndicator() {
        let memo = TimelineRowScanMemo()
        let body = "🔀 Subtask: Explore auth call sites"
        let indicator = text("1", body)
        let before = build([indicator, text("2", "b")], memo: memo)
        guard case .text = before.contents[0] else { return XCTFail("no child yet → text row") }
        let title = SubChatStripViewModel.subtaskDescription(fromMessageBody: body) ?? ""
        let child = SubChatSummary(id: "sub", title: title, isRunning: true)
        let after = build([indicator, text("2", "b")], memo: memo, children: [child])
        XCTAssertEqual(memo.lastScanCount, 2)
        guard case .hosted(let hosted) = after.contents[0] else { return XCTFail("child arrived → card") }
        XCTAssertEqual(hosted.subtaskChild?.id, "sub")
        XCTAssertEqual(after.contents, build([indicator, text("2", "b")], children: [child]).contents)
    }

    func test_memo_forgetsRowsThatLeaveTheWindow() {
        let memo = TimelineRowScanMemo()
        _ = build((0..<10).map { text("\($0)", "m") }, memo: memo)
        _ = build((5..<10).map { text("\($0)", "m") }, memo: memo)
        XCTAssertEqual(Set(memo.entries.keys), Set((5..<10).map { "\($0)" }))
    }
}

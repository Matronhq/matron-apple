#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronDesignSystem
import MatronModels
import MatronViewModels

private final class FakeChatForRooms: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

/// The chat header's "Rooms · n" and the side pane's header on a room
/// (Dan, 2026-10-01: every participant's chat opens its rooms beside it).
@MainActor
final class MacChatRoomsSnapshotTests: XCTestCase {
    private static let rooms = [
        ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — Bridge rollout order", state: .running),
        ConversationRoom(id: "r2", title: "G:c1 ↔️ P:85 — Which test account the sign-in check should use",
                         state: .waiting),
    ]

    private func header(rooms: [ConversationRoom], open: String? = nil, width: CGFloat) -> some View {
        let mission = ConversationMissionLink(
            mission: Mission(id: "ms_4706", num: 4706, title: "Unify web and Mac design", originConvoID: "c1"),
            isCurrent: true)
        let model = MacChatHeaderModel()
        model.props = MacChatToolbarProps(
            roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Bridge rollout", boxName: nil, styledTitle: nil, accessibilityTitle: nil,
            status: SessionStatus(model: "claude-fable-5-1",
                                  context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
                                  limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)]),
            stripViewModel: SubChatStripViewModel(chat: FakeChatForRooms(), parentConvoID: "c1"),
            missions: ConversationMissions(links: [mission]), projectTitles: [:],
            rooms: rooms, openRoomID: open, needsYouCount: 0, itemsAvailable: true,
            actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in }, onOpenProject: { _ in },
                           showMediaBrowser: .constant(false), showItemsPane: .constant(false)))
        return MacChatHeaderBar(model: model, hitRegions: MacChatHeaderHitRegions())
            .frame(width: width, height: 52)
    }

    func testHeaderWithTwoRooms() {
        assertVariants(of: header(rooms: Self.rooms, width: 1000), named: "header-rooms-two-1000")
    }

    func testHeaderWithOneRoom() {
        assertVariants(of: header(rooms: [Self.rooms[0]], width: 1000), named: "header-rooms-one-1000")
    }

    /// The control is its label's width and no wider, so it costs the
    /// title as little as it can.
    func testTheRoomsControlHugsItsLabel() {
        let strip = SubChatStripViewModel(chat: FakeChatForRooms(), parentConvoID: "c1")
        let item = MacChatToolbar(title: "T", status: nil, stripViewModel: strip, onOpenSubChat: { _ in },
                                  onCompact: {}, rooms: Self.rooms).roomsItem
        let width = NSHostingController(rootView: item)
            .sizeThatFits(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 52)).width
        XCTAssertGreaterThan(width, 40)
        XCTAssertLessThan(width, 110, "\"Rooms · 2\" measured \(width) pt")
    }

    private func paneHeader(roomID: String, showsBackChevron: Bool = false) -> some View {
        MacSubChatMiniHeader(
            room: MacRoomPaneContext(rooms: Self.rooms, onSwitch: { _ in }, onOpenAsChat: { _ in }),
            roomID: roomID, showsBackChevron: showsBackChevron, onClose: {})
            .frame(width: 380)
    }

    func testRoomPaneHeader() {
        assertVariants(of: paneHeader(roomID: "r1"), named: "room-pane-header-running")
        assertVariants(of: paneHeader(roomID: "r2", showsBackChevron: true), named: "room-pane-header-waiting-narrow")
    }

    /// A room the chat's list doesn't carry (not loaded yet, or a restored
    /// route to a room it left) still gets a header.
    func testRoomPaneHeader_forARoomNotInTheList() {
        let header = MacSubChatMiniHeader(
            room: MacRoomPaneContext(rooms: [], onSwitch: { _ in }, onOpenAsChat: nil),
            roomID: "gone", showsBackChevron: false, onClose: {})
        XCTAssertEqual(header.title, "Room")
        XCTAssertEqual(header.stateText, "")
        XCTAssertFalse(header.isRunning)
        XCTAssertNil(header.onOpenAsChat)
        XCTAssertTrue(header.siblings.isEmpty)
    }

    func testRoomPaneHeader_drawsTheRoomAndItsSiblings() {
        let header = MacSubChatMiniHeader(
            room: MacRoomPaneContext(rooms: Self.rooms, onSwitch: { _ in }, onOpenAsChat: { _ in }),
            roomID: "r2", showsBackChevron: false, onClose: {})
        XCTAssertEqual(header.title, Self.rooms[1].title)
        XCTAssertEqual(header.stateText, "Waiting")
        XCTAssertFalse(header.isRunning)
        XCTAssertEqual(header.siblings.map(\.id), ["r1", "r2"])
        XCTAssertEqual(header.siblings.map(\.isRunning), [true, false])
        XCTAssertEqual(header.currentID, "r2")
        XCTAssertEqual(header.noun, "room")
        XCTAssertNotNil(header.onOpenAsChat)
    }
}
#endif

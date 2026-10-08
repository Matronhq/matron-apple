import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ConversationRoomsFormatTests: XCTestCase {
    private static let rooms = [
        ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — Bridge rollout order", state: .running),
        ConversationRoom(id: "r2", title: "G:c1 ↔️ P:85 — Which test account the sign-in check should use",
                         state: .waiting),
        ConversationRoom(id: "r3", title: "G:c1 ↔️ G:0b — Tier labels for the next batch", state: .done),
    ]

    // MARK: iOS header subtitle with the rooms chip

    private func subtitle(_ context: String?, _ missions: ConversationMissions, rooms: Int) -> some View {
        ChatHeaderSubtitle(context: context, missions: missions, onTapChip: {}, roomCount: rooms, onTapRooms: {})
            .frame(width: 300).padding(4)
    }

    /// No mission: the workdir and the rooms chip share the line.
    func testSubtitleWithRoomsOnly() {
        assertVariants(of: subtitle("pat · ~/Dev/matron-apple", ConversationMissions(), rooms: 2),
                       named: "chat-subtitle-rooms-only")
    }

    /// A mission and rooms: both chips on the compact line, the mission's
    /// name truncating, "Rooms · n" whole.
    func testSubtitleWithAMissionAndRooms() {
        assertVariants(of: subtitle(ConversationMissionsSnapshotTests.longWorkdir,
                                    ConversationMissionsSnapshotTests.missions, rooms: 12),
                       named: "chat-subtitle-mission-and-rooms")
    }

    func testRoomsList() {
        assertVariants(of: ConversationRoomsList(rooms: Self.rooms, onOpen: { _ in }).frame(width: 390, height: 320),
                       named: "conversation-rooms-list")
    }

    func testLabelIsRoomsAndTheCount_andNothingForAChatInNoRoom() {
        XCTAssertNil(ConversationRoomsFormat.label(count: 0))
        XCTAssertEqual(ConversationRoomsFormat.label(count: 1), "Rooms · 1")
        XCTAssertEqual(ConversationRoomsFormat.label(count: 12), "Rooms · 12")
    }

    func testVoiceOverReadsTheCountAsWords() {
        XCTAssertEqual(ConversationRoomsFormat.accessibilityLabel(count: 1), "1 agent chat room")
        XCTAssertEqual(ConversationRoomsFormat.accessibilityLabel(count: 3), "3 agent chat rooms")
    }

    func testARoomRowReadsItsStateThenItsTitle() {
        let room = ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — rollout", state: .running)
        XCTAssertEqual(ConversationRoomsFormat.rowAccessibilityLabel(room), "Running, G:c1 ↔️ D:15 — rollout")
    }

    /// The iOS header's second line: a rooms chip counts as a chip, with
    /// or without a mission chip beside it.
    func testSubtitleLayoutCountsTheRoomsChip() {
        let none = ConversationMissions()
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "pat · ~/x", missions: none, roomCount: 2), .contextAndChip)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: none, roomCount: 1), .chipOnly)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "pat · ~/x", missions: none, roomCount: 0), .contextOnly)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: none, roomCount: 0), .none)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: ConversationMissionsSnapshotTests.missions,
                                                 roomCount: 2), .chipOnly)
    }
}

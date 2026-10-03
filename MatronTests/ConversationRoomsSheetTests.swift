import XCTest
import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
@testable import Matron

final class ConversationRoomsSheetTests: XCTestCase {
    private let one = ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — rollout", state: .running)
    private let two = ConversationRoom(id: "r2", title: "G:c1 ↔️ P:85 — test account", state: .waiting)

    /// One room: the sheet opens straight on it. Several: on the list.
    func test_theSheetOpensOnTheRoom_whenThereIsOnlyOne() {
        XCTAssertEqual(ConversationRoomsSheet.soleRoomID([one]), "r1")
        XCTAssertNil(ConversationRoomsSheet.soleRoomID([one, two]))
        XCTAssertNil(ConversationRoomsSheet.soleRoomID([]))
    }

    /// The room's title in the sheet follows the chat's live list, and a
    /// room that has left the list keeps a plain title.
    func test_roomTitle_comesFromTheList() {
        XCTAssertEqual(ConversationRoomsSheet.title(of: "r2", in: [one, two]), two.title)
        XCTAssertEqual(ConversationRoomsSheet.title(of: "gone", in: [one, two]), "Room")
    }

    /// A subtask card in a ROOM's timeline pushes the subagent on top of
    /// the room, so Back returns to the room (Bugbot, PR #317: the tap did
    /// nothing, the sheet having no stack for it). In a subagent's own
    /// timeline it still replaces the open child with its sibling.
    func test_aSubtaskInARoom_pushesOnTopOfTheRoom() {
        XCTAssertEqual(SubChatView.pathOpening("child", from: "r1", isRoom: true, in: []), ["child"],
                       "the sheet's root room is not on the path")
        XCTAssertEqual(SubChatView.pathOpening("child", from: "r1", isRoom: true, in: ["r1"]), ["r1", "child"])
        XCTAssertNil(SubChatView.pathOpening("child", from: "r1", isRoom: true, in: ["r1", "child"]),
                     "a second tap does not push it twice")
        XCTAssertEqual(SubChatView.pathOpening("sibling", from: "child", isRoom: false, in: ["r1", "child"]),
                       ["r1", "sibling"])
        XCTAssertNil(SubChatView.pathOpening("child", from: "child", isRoom: false, in: ["r1", "child"]))
    }

    /// The header's second line counts the rooms chip as a chip.
    func test_theHeaderSubtitleShowsTheRoomsChip() {
        XCTAssertEqual(ChatView.headerSubtitleLayout(context: "pat · ~/yearbook-app", missions: ConversationMissions(),
                                                     roomCount: 2), .contextAndChip)
        XCTAssertEqual(ChatView.headerSubtitleLayout(context: nil, missions: ConversationMissions(), roomCount: 1),
                       .chipOnly)
        XCTAssertEqual(ChatView.headerSubtitleLayout(context: "pat · ~/yearbook-app", missions: ConversationMissions()),
                       .contextOnly, "a chat in no room is today's header")
    }
}

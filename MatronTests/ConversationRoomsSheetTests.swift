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

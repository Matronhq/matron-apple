import XCTest
import MatronModels
@testable import MatronChat

/// The conversation chooser's box filter (Coordinator, Pinned chats → Add,
/// Move pin…): which boxes it offers and what picking one keeps.
final class ChatBoxFilterTests: XCTestCase {
    private let bot = BotIdentity(matrixID: "@b:s", displayName: "Bot", avatarURL: nil)

    private func chat(_ id: String, _ title: String, box: String? = nil, room: [String] = []) -> ChatSummary {
        ChatSummary(id: id, title: title, bot: bot, lastActivity: .now, unreadCount: 0,
                    boxName: box, roomBoxNames: room)
    }

    private lazy var chats = [
        chat("1", "Triage desk", box: "triage-box"),
        chat("2", "Docs desk", box: "lab-mac"),
        chat("3", "Release notes", box: "lab-mac"),
        chat("4", "Untagged"),
        chat("5", "Desk room", box: "lab-mac", room: ["lab-mac", "pat"]),
    ]

    func test_counts_mostFirstThenByName_roomsCountOnEachBox_untaggedLeftOut() {
        XCTAssertEqual(ChatBoxFilter.counts(chats), [
            ProjectBoxCount(box: "lab-mac", count: 3),
            ProjectBoxCount(box: "pat", count: 1),
            ProjectBoxCount(box: "triage-box", count: 1),
        ])
    }

    func test_boxes_dedupesARoomsOwnBox() {
        XCTAssertEqual(ChatBoxFilter.boxes(of: chats[4]), ["lab-mac", "pat"])
        XCTAssertEqual(ChatBoxFilter.boxes(of: chats[0]), ["triage-box"])
        XCTAssertEqual(ChatBoxFilter.boxes(of: chats[3]), [])
    }

    func test_shows_onlyWithTwoOrMoreBoxes() {
        XCTAssertTrue(ChatBoxFilter.shows(ChatBoxFilter.counts(chats)))
        XCTAssertFalse(ChatBoxFilter.shows(ChatBoxFilter.counts([chats[1], chats[2]])))
        // A single-box user's rows carry no box at all.
        XCTAssertFalse(ChatBoxFilter.shows(ChatBoxFilter.counts([chat("a", "A"), chat("b", "B")])))
    }

    func test_filtered_byBox_includesRoomsOnThatBox() {
        XCTAssertEqual(ChatBoxFilter.filtered(chats, query: "", box: "lab-mac").map(\.id), ["2", "3", "5"])
        XCTAssertEqual(ChatBoxFilter.filtered(chats, query: "", box: "pat").map(\.id), ["5"])
        XCTAssertEqual(ChatBoxFilter.filtered(chats, query: "", box: nil).count, 5)
    }

    func test_filtered_combinesQueryAndBox() {
        XCTAssertEqual(ChatBoxFilter.filtered(chats, query: " DESK ", box: nil).map(\.id), ["1", "2", "5"])
        XCTAssertEqual(ChatBoxFilter.filtered(chats, query: "desk", box: "lab-mac").map(\.id), ["2", "5"])
        XCTAssertTrue(ChatBoxFilter.filtered(chats, query: "release", box: "triage-box").isEmpty)
    }

    func test_activeBox_fallsBackToAllWhenTheBoxIsGone() {
        let counts = ChatBoxFilter.counts(chats)
        XCTAssertEqual(ChatBoxFilter.activeBox("pat", in: counts), "pat")
        XCTAssertNil(ChatBoxFilter.activeBox("docs-box", in: counts))
        XCTAssertNil(ChatBoxFilter.activeBox(nil, in: counts))
    }
}

#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels

/// Inert `ChatService` stub — the toolbar tests only need a strip VM to
/// exist; its observation is never started.
private final class FakeChatForToolbar: ChatService, @unchecked Sendable {
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        AsyncStream { $0.finish() }
    }
    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createChat(with botID: String) async throws -> String { "!x:s" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func leave(roomID: String) async throws {}
}

@MainActor
final class MacChatToolbarTests: XCTestCase {

    private func makeStripVM() -> SubChatStripViewModel {
        SubChatStripViewModel(chat: FakeChatForToolbar(), parentConvoID: "p1")
    }

    func testToolbarCarriesTitleAndStatus() {
        let status = SessionStatus(
            model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27),
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: nil, resetsAt: nil)])
        let toolbar = MacChatToolbar(
            title: "Chat", status: status,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(toolbar.title, "Chat")
        XCTAssertEqual(toolbar.status?.context?.pct, 27)
        XCTAssertEqual(toolbar.status?.limits?.count, 1)

        // Nil status is valid — header renders the title alone.
        XCTAssertNil(MacChatToolbar(
            title: "Chat", status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {}).status)
    }

    /// The under-title line joins the home-abbreviated workdir and the
    /// account email with a middle dot; either alone stands by itself, and
    /// with neither the line disappears (nil, not an empty Text).
    func testTitleSubtitleJoinsWorkdirAndEmail() {
        func toolbar(workdir: String? = nil, email: String? = nil) -> MacChatToolbar {
            MacChatToolbar(
                title: "Chat",
                status: SessionStatus(email: email, workdir: workdir),
                stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        }
        XCTAssertEqual(
            toolbar(workdir: "/Users/dan/Dev/matron-bridge", email: "dan@example.com").titleSubtitle,
            "~/Dev/matron-bridge · dan@example.com")
        XCTAssertEqual(toolbar(workdir: "/opt/matron").titleSubtitle, "/opt/matron")
        XCTAssertEqual(toolbar(email: "dan@example.com").titleSubtitle, "dan@example.com")
        XCTAssertNil(toolbar().titleSubtitle)
    }

    /// The leading cluster's first line carries the effort beside the
    /// model when the bridge is tracking one, and nothing extra when it
    /// isn't — the cluster's height is budgeted for three caption lines,
    /// so effort shares the model's rather than taking a fourth. With no
    /// model the line is nil (dropped), not an empty Text.
    func testModelLineCarriesEffortBesideTheModel() {
        func toolbar(model: String? = nil, effort: String? = nil) -> MacChatToolbar {
            MacChatToolbar(
                title: "Chat",
                status: SessionStatus(model: model, effort: effort),
                stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        }
        XCTAssertEqual(toolbar(model: "opus", effort: "xhigh").modelLine, "opus · xhigh")
        XCTAssertEqual(toolbar(model: "opus").modelLine, "opus",
                       "an untracked effort adds nothing — no separator, no reserved space")
        XCTAssertNil(toolbar(effort: "xhigh").modelLine,
                     "effort qualifies a model; with no model there is no line to qualify")
        XCTAssertNil(toolbar().modelLine)
    }


    /// "Open project" names the headline mission's project, and only when
    /// this device knows its title.
    func testTheMenusOpenProjectEntryNeedsAKnownProject() {
        let filed = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1",
                                                             projectID: "pj_1"), isCurrent: true)
        let missions = ConversationMissions(links: [filed])
        XCTAssertEqual(MacChatToolbar.menuProjectID(missions: missions, projectTitles: ["pj_1": "Promo"]), "pj_1")
        XCTAssertNil(MacChatToolbar.menuProjectID(missions: missions, projectTitles: [:]))
        XCTAssertNil(MacChatToolbar.menuProjectID(missions: ConversationMissions(), projectTitles: ["pj_1": "Promo"]))
    }

    /// PR4 review M3: titles come from the observed projects list, so a
    /// `/projects` landing (or a rename) reaches the menu without a mission
    /// change; only the conversation's own missions' projects are named.
    func testMissionProjectTitlesComeFromTheKnownProjects() {
        let filed = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1",
                                                             projectID: "pj_1"), isCurrent: true)
        let unfiled = ConversationMissionLink(mission: Mission(id: "ms_2", num: 62, title: "N", originConvoID: "c1"))
        let missions = ConversationMissions(links: [filed, unfiled])
        XCTAssertEqual(MacChatView.missionProjectTitles(missions: missions, projects: []), [:],
                       "nothing known yet: no Open project")
        let projects = [Project(id: "pj_1", num: 1, title: "Promo"), Project(id: "pj_9", num: 9, title: "Other")]
        XCTAssertEqual(MacChatView.missionProjectTitles(missions: missions, projects: projects), ["pj_1": "Promo"])
        let renamed = [Project(id: "pj_1", num: 1, title: "Promo launch")]
        XCTAssertEqual(MacChatView.missionProjectTitles(missions: missions, projects: renamed), ["pj_1": "Promo launch"])
        XCTAssertEqual(MacChatView.missionProjectTitles(missions: ConversationMissions(), projects: projects), [:])
    }

    /// The header republishes when the missions change.
    func testPropsEqualityCoversTheMissions() {
        let strip = makeStripVM()
        func props(_ missions: ConversationMissions) -> MacChatToolbarProps {
            MacChatToolbarProps(roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                title: "T", boxName: nil, styledTitle: nil, accessibilityTitle: nil, status: nil,
                                stripViewModel: strip, missions: missions, projectTitles: [:], needsYouCount: 0,
                                itemsAvailable: true,
                                actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                                               onOpenProject: { _ in }, showMediaBrowser: .constant(false),
                                               showItemsPane: .constant(false)))
        }
        let link = ConversationMissionLink(mission: Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"),
                                           isCurrent: true)
        XCTAssertNotEqual(props(ConversationMissions()), props(ConversationMissions(links: [link])))
    }

    /// The header republishes when this chat's rooms change, and when the
    /// room open in the side pane does (the menu ticks it).
    func testPropsEqualityCoversTheRooms() {
        let strip = makeStripVM()
        func props(rooms: [ConversationRoom] = [], open: String? = nil) -> MacChatToolbarProps {
            MacChatToolbarProps(roomID: "c1", publisher: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                title: "T", boxName: nil, styledTitle: nil, accessibilityTitle: nil, status: nil,
                                stripViewModel: strip, missions: ConversationMissions(), projectTitles: [:],
                                rooms: rooms, openRoomID: open, needsYouCount: 0, itemsAvailable: true,
                                actions: .init(onOpenSubChat: { _ in }, onCompact: {}, onOpenMission: { _ in },
                                               onOpenProject: { _ in }, showMediaBrowser: .constant(false),
                                               showItemsPane: .constant(false)))
        }
        let room = ConversationRoom(id: "r1", title: "G:c1 ↔️ D:15 — rollout", state: .waiting)
        XCTAssertEqual(props(rooms: [room]), props(rooms: [room]))
        XCTAssertNotEqual(props(), props(rooms: [room]))
        XCTAssertNotEqual(props(rooms: [room]), props(rooms: [room], open: "r1"))
    }

    /// "Rooms · n" shows only for a chat that is in a room, and carries
    /// every room it is in.
    func testRoomsControlShowsForAChatInARoom() {
        func toolbar(_ rooms: [ConversationRoom]) -> MacChatToolbar {
            MacChatToolbar(title: "Chat", status: nil, stripViewModel: makeStripVM(), onOpenSubChat: { _ in },
                           onCompact: {}, rooms: rooms)
        }
        XCTAssertNil(toolbar([]).roomsLabel)
        let one = ConversationRoom(id: "r1", title: "A", state: .waiting)
        let two = ConversationRoom(id: "r2", title: "B", state: .running)
        XCTAssertEqual(toolbar([one]).roomsLabel, "Rooms · 1")
        XCTAssertEqual(toolbar([one, two]).roomsLabel, "Rooms · 2")
    }

    /// A pick opens the room; picking the room already open closes the pane.
    func testPickingTheOpenRoomClosesIt() {
        XCTAssertEqual(MacChatToolbar.roomAfterPick("r1", open: nil), "r1")
        XCTAssertEqual(MacChatToolbar.roomAfterPick("r2", open: "r1"), "r2")
        XCTAssertNil(MacChatToolbar.roomAfterPick("r1", open: "r1"))
    }

    /// The sidebar-toggle button posts `.toggleSidebar` on the command
    /// bus. The toolbar tests the listener side; Task 14e tests the
    /// menu-bar `Button("Toggle Sidebar")` poster side. Verifying the
    /// `Notification.Name` exists and is distinct keeps the contract
    /// explicit before the menu item lands.
    func test_toggleSidebarNotificationName_isWired() {
        let name = Notification.Name.matronCommand(.toggleSidebar)
        XCTAssertEqual(name.rawValue, "chat.matron.command.toggleSidebar")
    }

    /// The box name leads the subtitle — "which machine am I talking to"
    /// outranks the path and the account. Nil (fewer than two boxes) leaves
    /// the line exactly as it was.
    func testTitleSubtitleLeadsWithTheBoxName() {
        let toolbar = MacChatToolbar(
            title: "Fix the parser", boxName: "dev-y",
            status: SessionStatus(email: "dan@example.com", workdir: "/Users/dan/proj"),
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(toolbar.titleSubtitle, "dev-y · ~/proj · dan@example.com")

        let boxOnly = MacChatToolbar(
            title: "Fix the parser", boxName: "dev-y", status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertEqual(boxOnly.titleSubtitle, "dev-y")

        let none = MacChatToolbar(
            title: "Fix the parser", boxName: nil, status: nil,
            stripViewModel: makeStripVM(), onOpenSubChat: { _ in }, onCompact: {})
        XCTAssertNil(none.titleSubtitle)
    }
}
#endif

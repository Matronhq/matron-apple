import XCTest
import MatronModels

/// The project page's "Sessions on it now" rows and box filter, and its
/// "Other open items" grouping, ordering and fold (tracker 5671).
final class ProjectPageSectionsTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    private static func mission(_ num: Int, state: MissionState = .open) -> Mission {
        Mission(id: "ms_\(num)", num: num, state: state, title: "Mission \(num)", originConvoID: "c1", projectID: "pj_1")
    }

    private static func row(_ num: Int) -> MissionRowModel {
        MissionRowModel(mission: mission(num), activity: .running, lastActivity: now)
    }

    private static func session(_ id: String, _ state: DashboardSessionState, box: String?, age: TimeInterval? = nil,
                                tagged: Bool = true) -> DashboardSession {
        DashboardSession(id: id, title: id, state: state, lastActivity: age.map(ago),
                         tag: tagged ? box.map { SessionTagInputs(boxLetter: nil, boxName: $0, sessionShort: nil) } : nil,
                         boxName: tagged ? nil : box)
    }

    private static func item(_ num: Int, mission: Int?, awaiting: ItemAwaiting?, age: TimeInterval = 0) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: .task, awaiting: awaiting, title: "Item \(num)", originConvoID: "c1",
                    updatedAt: ago(age), missionID: mission.map { "ms_\($0)" }, missionNum: mission)
    }

    // MARK: Sessions

    func testSessionRowsListEachSessionOnceWithEveryMissionInPageOrder() {
        let page = ProjectPageModel(
            project: Project(id: "pj_1", num: 1, title: "P"),
            missions: [Self.row(2), Self.row(1)],
            sessionsByMission: [
                "ms_1": [Self.session("a", .running, box: "greg", age: 60), Self.session("shared", .waiting, box: "bev")],
                "ms_2": [Self.session("shared", .waiting, box: "bev"), Self.session("d", .done, box: "pat", age: 5)],
                // A closed mission's sessions are not the project's now.
                "ms_9": [Self.session("gone", .running, box: "greg")],
            ])
        let rows = ProjectPageSections.sessionRows(page)
        XCTAssertEqual(rows.map(\.id), ["a", "shared", "d"], "running → waiting → done")
        XCTAssertEqual(rows.first { $0.id == "shared" }?.missions.map(\.num), [2, 1], "page order, both missions")
    }

    func testBoxCountsComeFromTheRowsMostFirstThenByName() {
        let rows = [Self.session("a", .running, box: "greg"), Self.session("b", .running, box: "bev"),
                    Self.session("c", .waiting, box: "greg"), Self.session("d", .waiting, box: "pat", tagged: false),
                    Self.session("e", .waiting, box: nil)]
            .map { ProjectSessionRow(session: $0, missions: []) }
        XCTAssertEqual(ProjectPageSections.boxCounts(rows, fallback: ["deploy-1": 8]),
                       [ProjectBoxCount(box: "greg", count: 2), ProjectBoxCount(box: "bev", count: 1),
                        ProjectBoxCount(box: "pat", count: 1)],
                       "an untagged session's bare box counts; a session with no box does not")
        XCTAssertEqual(ProjectPageSections.boxCounts([], fallback: ["pat": 1, "deploy-1": 8]),
                       [ProjectBoxCount(box: "deploy-1", count: 8), ProjectBoxCount(box: "pat", count: 1)],
                       "the journal's counts until the sessions load")
    }

    func testABoxClickFiltersAndASecondClickOrAllClears() {
        let rows = [Self.session("a", .running, box: "greg"), Self.session("b", .running, box: "bev")]
            .map { ProjectSessionRow(session: $0, missions: []) }
        let counts = ProjectPageSections.boxCounts(rows, fallback: [:])
        var selected = ProjectPageSections.toggled(nil, box: "bev")
        XCTAssertEqual(selected, "bev")
        XCTAssertEqual(ProjectPageSections.rows(rows, onBox: ProjectPageSections.activeBox(selected, in: counts)).map(\.id),
                       ["b"])
        selected = ProjectPageSections.toggled(selected, box: "bev")
        XCTAssertNil(selected, "clicking the selected box again clears")
        XCTAssertEqual(ProjectPageSections.rows(rows, onBox: selected).map(\.id), ["a", "b"])
        XCTAssertEqual(ProjectPageSections.toggled("bev", box: "greg"), "greg", "another box switches")
        XCTAssertNil(ProjectPageSections.activeBox("pat", in: counts), "a box with no sessions left filters nothing")
    }

    // MARK: Items

    private static func itemsPage(_ items: [TrackerItem], needsYou: [TrackerItem] = []) -> ProjectPageModel {
        ProjectPageModel(project: Project(id: "pj_1", num: 1, title: "P"),
                         missions: [row(2), row(1)], closedMissions: [mission(3, state: .closed)],
                         needsYou: needsYou, openItems: items + needsYou)
    }

    func testOtherItemsLeaveOutNeedsYouAndGroupByMissionInPageOrder() {
        let needsYou = Self.item(10, mission: 1, awaiting: .user)
        let page = Self.itemsPage([
            Self.item(1, mission: 1, awaiting: .agent, age: 50),
            Self.item(2, mission: 3, awaiting: .agent),
            Self.item(3, mission: 2, awaiting: nil),
            Self.item(4, mission: 7, awaiting: .agent),
            Self.item(5, mission: 1, awaiting: nil, age: 10),
            Self.item(6, mission: 1, awaiting: .agent, age: 5),
            Self.item(7, mission: 1, awaiting: .user, age: 100),
        ], needsYou: [needsYou])
        let list = ProjectPageSections.itemList(page, expanded: false)
        XCTAssertEqual(list.groups.map(\.missionID), ["ms_2", "ms_1", "ms_3", "ms_7"],
                       "open missions in page order, then closed, then missions the page doesn't know")
        XCTAssertEqual(list.groups[1].items.map(\.num), [7, 6, 1, 5],
                       "awaiting you (not already in Needs you), then agent newest first, then nobody")
        XCTAssertEqual(list.groups[3].title, "#7")
        XCTAssertEqual(list.groups[0].title, "#2 Mission 2")
        XCTAssertEqual(list.total, 7)
        XCTAssertEqual(list.hidden, 0)
    }

    func testOtherItemsFoldPastTheLimitAndShowAllUnfolds() {
        let items = (1...11).map { Self.item($0, mission: $0 <= 6 ? 2 : 1, awaiting: .agent, age: TimeInterval($0)) }
        let folded = ProjectPageSections.itemList(Self.itemsPage(items), expanded: false)
        XCTAssertEqual(folded.groups.flatMap(\.items).count, ProjectPageSections.foldedItemLimit)
        XCTAssertEqual(folded.groups.map { $0.items.count }, [6, 2], "the cut runs through the second group")
        XCTAssertEqual(folded.hidden, 3)
        XCTAssertEqual(folded.total, 11)
        let all = ProjectPageSections.itemList(Self.itemsPage(items), expanded: true)
        XCTAssertEqual(all.groups.flatMap(\.items).count, 11)
        XCTAssertEqual(all.hidden, 0)
    }

    func testExactlyTheLimitIsNotFolded() {
        let items = (1...ProjectPageSections.foldedItemLimit).map { Self.item($0, mission: 1, awaiting: .agent) }
        let list = ProjectPageSections.itemList(Self.itemsPage(items), expanded: false)
        XCTAssertEqual(list.hidden, 0)
        XCTAssertEqual(list.groups.count, 1)
    }
}

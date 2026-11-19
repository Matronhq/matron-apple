import XCTest
import MatronModels
@testable import MatronViewModels

final class ProjectsHomeFilterTests: XCTestCase {
    typealias F = ProjectsHomeAssemblyTests

    static func project(_ id: String, num: Int, _ title: String) -> Project {
        Project(id: id, num: num, title: title, createdAt: F.ago(F.day), updatedAt: F.ago(F.day),
                lastActivityAt: F.ago(TimeInterval(num)))
    }

    static func mission(_ id: String, num: Int, _ title: String, name: String? = nil, project: String? = nil,
                        state: MissionState = .open, quiet: Bool = false) -> Mission {
        Mission(id: id, num: num, state: state, title: title, originConvoID: "c1",
                createdAt: F.ago(30 * F.day), updatedAt: F.ago(30 * F.day),
                lastMilestoneAt: F.ago(quiet ? 9 * F.day : 60), closedAt: state == .closed ? F.ago(F.day) : nil,
                projectID: project, name: name)
    }

    /// Three projects, one named by its title, one only by a mission's
    /// title, one only by a closed mission's short name; and a mission of
    /// each kind outside any project.
    static var home: ProjectsHomeSnapshot {
        ProjectsHomeAssembly.assemble(
            projects: [project("pj_1", num: 1, "Docs site launch"), project("pj_2", num: 2, "Theme designer"),
                       project("pj_3", num: 3, "Docs pipeline"), project("pj_4", num: 4, "Billing")],
            missions: [mission("ms_10", num: 10, "Rewrite the getting-started page", project: "pj_1"),
                       mission("ms_11", num: 11, "Sidebar width in the theme", project: "pj_3"),
                       mission("ms_12", num: 12, "Old export", name: "Theme CSS export", project: "pj_4", state: .closed),
                       mission("ms_13", num: 13, "Invoices by email", project: "pj_4"),
                       mission("ms_20", num: 20, "Theme preview upload"),
                       mission("ms_21", num: 21, "Tidy the icons"),
                       mission("ms_22", num: 22, "Themes audit", quiet: true),
                       mission("ms_23", num: 23, "Subtheme option", state: .closed)],
            needsYouItems: [:], now: F.now)
    }

    func testAnEmptyOrBlankQueryKeepsEverything() {
        XCTAssertFalse(ProjectsHomeFilter("").isActive)
        XCTAssertFalse(ProjectsHomeFilter("  \n").isActive)
        XCTAssertEqual(ProjectsHomeFilter("").apply(to: Self.home), Self.home)
        XCTAssertEqual(ProjectsHomeFilter("   ").apply(to: Self.home), Self.home)
    }

    func testCardsCarryTheirMissionsTitlesAndNamesOpenFirst() {
        let billing = Self.home.cards.first { $0.id == "pj_4" }
        XCTAssertEqual(billing?.missionTitles, ["Invoices by email", "Old export", "Theme CSS export"])
    }

    func testAProjectIsFoundByItsTitleOrByAMissionsTitleOrName() {
        let filtered = ProjectsHomeFilter("theme").apply(to: Self.home)
        XCTAssertEqual(filtered.cards.map(\.id), ["pj_2", "pj_3", "pj_4"], "the title match leads")
        XCTAssertEqual(filtered.unfiled.map(\.id), ["ms_20"])
        XCTAssertEqual(filtered.quiet.map(\.id), ["ms_22"])
        XCTAssertEqual(filtered.closed.map(\.id), ["ms_23", "ms_12"], "inside a word, and by the short name")
        XCTAssertEqual(filtered.statusRefreshedAt, Self.home.statusRefreshedAt)
    }

    func testEveryWordMustMatchInAnyOrderIgnoringCaseAndAccents() {
        func cards(_ query: String) -> [String] { ProjectsHomeFilter(query).apply(to: Self.home).cards.map(\.id) }
        XCTAssertEqual(cards("DESIGNER theme"), ["pj_2"])
        XCTAssertEqual(cards("thème sidebar"), ["pj_3"])
        XCTAssertEqual(cards("docs theme"), ["pj_3"], "one word in the title, the other in a mission")
        XCTAssertEqual(cards("theme zebra"), [])
        XCTAssertTrue(ProjectsHomeFilter("zebra").apply(to: Self.home).isEmpty)
    }

    func testNumbersMatch() {
        XCTAssertEqual(ProjectsHomeFilter("#3").apply(to: Self.home).cards.map(\.id), ["pj_3"])
        XCTAssertEqual(ProjectsHomeFilter("#21").apply(to: Self.home).unfiled.map(\.id), ["ms_21"])
    }

    func testTheMatchedMissionIsNamedOnlyWhenTheTitleDoesNotMatch() {
        let cards = Dictionary(uniqueKeysWithValues: Self.home.cards.map { ($0.id, $0) })
        let filter = ProjectsHomeFilter("theme")
        XCTAssertNil(filter.matchedMission(in: cards["pj_2"]!))
        XCTAssertEqual(filter.matchedMission(in: cards["pj_3"]!), "Sidebar width in the theme")
        XCTAssertEqual(filter.matchedMission(in: cards["pj_4"]!), "Theme CSS export")
        XCTAssertEqual(ProjectsHomeFilter("docs theme").matchedMission(in: cards["pj_3"]!), "Sidebar width in the theme")
        XCTAssertNil(ProjectsHomeFilter("").matchedMission(in: cards["pj_3"]!))
    }

    /// With the words split between the title and a mission, the mission
    /// named is the one that supplied the missing word, not an earlier
    /// one that only repeats the title's.
    func testTheMatchedMissionIsTheOneThatSuppliedTheMissingWord() {
        let card = ProjectCard(project: Self.project("pj_9", num: 9, "Docs pipeline"),
                               missionTitles: ["Docs queue", "Sidebar width in the theme"])
        XCTAssertEqual(ProjectsHomeFilter("docs theme").matchedMission(in: card), "Sidebar width in the theme")
    }

    /// The "Move to project…" menu keeps every open project while the
    /// page is filtered: hosts read it from the unfiltered snapshot.
    func testFilteringNarrowsOpenProjects() {
        XCTAssertEqual(Self.home.openProjects.count, 4)
        XCTAssertEqual(ProjectsHomeFilter("billing").apply(to: Self.home).openProjects.map(\.id), ["pj_4"])
    }
}

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
            projects: [project("pj_1", num: 1, "Docs site launch"), project("pj_2", num: 2, "Cover designer"),
                       project("pj_3", num: 3, "Print pipeline"), project("pj_4", num: 4, "Billing")],
            missions: [mission("ms_10", num: 10, "Rewrite the getting-started page", project: "pj_1"),
                       mission("ms_11", num: 11, "Spine width on the cover", project: "pj_3"),
                       mission("ms_12", num: 12, "Old export", name: "Cover PDF export", project: "pj_4", state: .closed),
                       mission("ms_13", num: 13, "Invoices by email", project: "pj_4"),
                       mission("ms_20", num: 20, "Cover photo upload"),
                       mission("ms_21", num: 21, "Tidy the icons"),
                       mission("ms_22", num: 22, "Covers audit", quiet: true),
                       mission("ms_23", num: 23, "Hardcover option", state: .closed)],
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
        XCTAssertEqual(billing?.missionTitles, ["Invoices by email", "Old export", "Cover PDF export"])
    }

    func testAProjectIsFoundByItsTitleOrByAMissionsTitleOrName() {
        let filtered = ProjectsHomeFilter("cover").apply(to: Self.home)
        XCTAssertEqual(filtered.cards.map(\.id), ["pj_2", "pj_3", "pj_4"], "the title match leads")
        XCTAssertEqual(filtered.unfiled.map(\.id), ["ms_20"])
        XCTAssertEqual(filtered.quiet.map(\.id), ["ms_22"])
        XCTAssertEqual(filtered.closed.map(\.id), ["ms_23", "ms_12"], "inside a word, and by the short name")
        XCTAssertEqual(filtered.statusRefreshedAt, Self.home.statusRefreshedAt)
    }

    func testEveryWordMustMatchInAnyOrderIgnoringCaseAndAccents() {
        func cards(_ query: String) -> [String] { ProjectsHomeFilter(query).apply(to: Self.home).cards.map(\.id) }
        XCTAssertEqual(cards("DESIGNER cover"), ["pj_2"])
        XCTAssertEqual(cards("cóver spine"), ["pj_3"])
        XCTAssertEqual(cards("print cover"), ["pj_3"], "one word in the title, the other in a mission")
        XCTAssertEqual(cards("cover zebra"), [])
        XCTAssertTrue(ProjectsHomeFilter("zebra").apply(to: Self.home).isEmpty)
    }

    func testNumbersMatch() {
        XCTAssertEqual(ProjectsHomeFilter("#3").apply(to: Self.home).cards.map(\.id), ["pj_3"])
        XCTAssertEqual(ProjectsHomeFilter("#21").apply(to: Self.home).unfiled.map(\.id), ["ms_21"])
    }

    func testTheMatchedMissionIsNamedOnlyWhenTheTitleDoesNotMatch() {
        let cards = Dictionary(uniqueKeysWithValues: Self.home.cards.map { ($0.id, $0) })
        let filter = ProjectsHomeFilter("cover")
        XCTAssertNil(filter.matchedMission(in: cards["pj_2"]!))
        XCTAssertEqual(filter.matchedMission(in: cards["pj_3"]!), "Spine width on the cover")
        XCTAssertEqual(filter.matchedMission(in: cards["pj_4"]!), "Cover PDF export")
        XCTAssertEqual(ProjectsHomeFilter("print cover").matchedMission(in: cards["pj_3"]!), "Spine width on the cover")
        XCTAssertNil(ProjectsHomeFilter("").matchedMission(in: cards["pj_3"]!))
    }

    /// The "Move to project…" menu keeps every open project while the
    /// page is filtered: hosts read it from the unfiltered snapshot.
    func testFilteringNarrowsOpenProjects() {
        XCTAssertEqual(Self.home.openProjects.count, 4)
        XCTAssertEqual(ProjectsHomeFilter("billing").apply(to: Self.home).openProjects.map(\.id), ["pj_4"])
    }
}

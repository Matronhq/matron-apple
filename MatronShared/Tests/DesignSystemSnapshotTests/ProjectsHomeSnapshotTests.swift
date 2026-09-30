import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectsHomeSnapshotTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    static var home: ProjectsHomeSnapshot {
        let apps = Project(id: "pj_3", num: 4002, title: "Matron apps",
                           status: "AppKit timeline waits on your manual pass. Projects redesign plan is ready for review.",
                           statusBy: .agent, statusUpdatedAt: F.ago(240),
                           missions: ProjectMissionCounts(running: 3, waiting: 4, quiet: 4), needsYou: 3,
                           lastActivityAt: F.ago(120))
        let unfiled = (0..<8).map { i in
            F.row(5100 + i, "Unfiled mission \(i + 1)", activity: i == 0 ? .running : .waiting,
                  status: "Status line for mission \(i + 1).", needsYou: i == 1 ? 1 : 0, age: TimeInterval(60 * (i + 4)))
        }
        return ProjectsHomeSnapshot(
            cards: [ProjectCard(project: F.promo, needsYouCount: 6), ProjectCard(project: apps, needsYouCount: 3),
                    ProjectCard(project: F.silent, needsYouCount: 0)],
            unfiled: unfiled,
            quiet: [F.row(2000, "Old thing", activity: .quiet, status: nil, age: 20 * 86_400)],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker", closeSummary: "Shipped.",
                             originConvoID: "c0", closedAt: F.ago(9 * 86_400))],
            statusRefreshedAt: F.ago(1_200))
    }

    private func page(_ home: ProjectsHomeSnapshot) -> ProjectsHomeView {
        ProjectsHomeView(model: .init(home: home, isRefreshing: false, askedAt: nil, isAskEnabled: true, canCreateProject: true),
                         now: F.now, onAction: { _ in }, onRefresh: {}, onAsk: {})
    }

    func testModelFlags() {
        XCTAssertEqual(ProjectsHomeView.unfiledPreview, 6)
        XCTAssertTrue(ProjectsHomeSnapshot().isEmpty)
        XCTAssertEqual(Self.home.openProjects.map(\.id), ["pj_1", "pj_3", "pj_2"])
    }

    func testHomeEmpty() {
        assertVariants(of: page(ProjectsHomeSnapshot()).frame(width: 390, height: 360), named: "projects-home-empty")
    }

    func testHomePhoneWidth() {
        assertVariants(of: page(Self.home).frame(width: 390, height: 1_500), named: "projects-home-phone")
    }

    func testHomeMacWidth() {
        assertVariants(of: page(Self.home).frame(width: 1_280, height: 1_000), named: "projects-home-wide")
    }

    func testNewProjectSheet() {
        assertVariants(of: NewProjectSheet(onCreate: { _, _ in nil }, onCancel: {}).frame(width: 440),
                       named: "projects-new-sheet")
    }
}

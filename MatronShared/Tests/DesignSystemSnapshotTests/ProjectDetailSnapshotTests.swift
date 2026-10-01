import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectDetailSnapshotTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    static var page: ProjectPageModel {
        let branch = F.row(4791, "Promo branch: /proto design at the base URLs", activity: .waiting,
                           status: "R2 redirect test done on 328 addresses; infra PR 605 needs the blog nginx line.",
                           needsYou: 2, age: 660)
        let launch = F.row(4907, "Launch day: Wed 7 Oct 07:00", activity: .running,
                           status: "Branch green at b6794bffa8; S7 confirmed.", age: 660)
        return ProjectPageModel(
            project: F.promo,
            missions: [branch, launch],
            closedMissions: [Mission(id: "ms_c", num: 4000, state: .closed, title: "Old promo", originConvoID: "c1")],
            needsYou: [TrackerItem(id: "it_1", num: 8666, kind: .question, awaiting: .user,
                                   title: "Leavers' page PR 8666 — ship with launch?", originConvoID: "c1",
                                   missionID: "ms_4791", missionNum: 4791),
                       TrackerItem(id: "it_2", num: 8667, kind: .question, awaiting: .user, title: "Cloudflare API token scope",
                                   originConvoID: "c1", missionID: "ms_4907", missionNum: 4907)],
            recentMilestones: [Milestone(id: "ml_1", missionID: "ms_4907", num: 9001, kind: .progress,
                                         title: "S7 confirmed: no Cloudflare rule caches HTML", convoID: "c1", seq: 1,
                                         createdAt: F.ago(660)),
                               Milestone(id: "ml_2", missionID: "ms_4907", num: 9002, kind: .userInput,
                                         title: "Dan chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1", seq: 2,
                                         createdAt: F.ago(13 * 3_600))],
            missionNums: ["ms_4791": 4791, "ms_4907": 4907],
            sessionsByBox: ["greg": 2, "pat": 1, "dan-mac": 1],
            sessionsByMission: ["ms_4791": [
                DashboardSession(id: "c-p", title: "promo/integration owner", state: .waiting,
                                 tag: SessionTagInputs(boxLetter: "P", boxName: "pat", sessionShort: "ad")),
                DashboardSession(id: "c-g", title: "sales-chat", state: .running,
                                 tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
                DashboardSession(id: "c-d", title: "done one", state: .done, boxName: "bev"),
            ]])
    }

    func testProjectPagePhone() {
        assertVariants(of: ProjectDetailView(page: Self.page, now: F.now, onOpenMission: { _ in }, onOpenItem: { _ in },
                                             onOpenSession: { _ in }, onOpenMilestone: { _ in }, onMoveMission: { _, _ in }, onRefresh: {})
            .frame(width: 390, height: 1_400), named: "project-page-phone")
    }

    func testSessionRowMetaLine() {
        let m1 = Mission(id: "ms_1", num: 4791, title: "Promo branch", originConvoID: "c1")
        let m2 = Mission(id: "ms_2", num: 4907, title: "Launch day", originConvoID: "c1")
        let stalled = DashboardSession(id: "c", title: "t", state: .waiting, model: "opus", isStalled: true)
        XCTAssertEqual(ProjectSessionRowView.metaLine(ProjectSessionRow(session: stalled, missions: [m1])),
                       "opus · stalled · #4791 Promo branch")
        XCTAssertEqual(ProjectSessionRowView.metaLine(ProjectSessionRow(session: stalled, missions: [m1, m2])),
                       "opus · stalled · #4791, #4907")
        XCTAssertNil(ProjectSessionRowView.metaLine(ProjectSessionRow(
            session: DashboardSession(id: "c", title: "t", state: .done), missions: [])))
    }

    func testSessionChipLineCapsAtTwoAndCountsTheRest() {
        XCTAssertEqual(SessionChipLine.moreText(total: 3, limit: 2), "+1 more")
        XCTAssertNil(SessionChipLine.moreText(total: 2, limit: 2))
    }
}

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

    /// `page` with the journal's roll-up: an answered question, a reversed
    /// decision, files from an item and a chat, milestones over two days.
    static var pageWithFeed: ProjectPageModel {
        var page = Self.page
        page.decisions = ProjectFeedPage(total: 9, rows: [
            ProjectDecision(id: "it_d1", num: 8690, kind: .question, state: .closed, resolution: .answered,
                            title: "Approve the sales chat for launch?", createdAt: F.ago(30 * 3_600),
                            closedAt: F.ago(20 * 3_600), missionNum: 4791, answer: "Yes, ship it with the chat on."),
            ProjectDecision(id: "it_d2", num: 8691, kind: .decision, title: "Home shows the Blue cover as the app renders it",
                            createdAt: F.ago(3 * 86_400), missionNum: 4791),
            ProjectDecision(id: "it_d3", num: 8692, kind: .decision, state: .closed, resolution: .reversed,
                            title: "/contacts redirects to /book-design", createdAt: F.ago(4 * 86_400), missionNum: 4907),
        ], nextBefore: "cursor")
        page.files = ProjectFeedPage(total: 3, rows: [
            ProjectFile(blobID: "b1", name: "Leavers page desktop.png", contentType: "image/png", missionNum: 4791,
                        source: .item(num: 8666), postedAt: F.ago(86_400)),
            ProjectFile(blobID: "b2", name: "Claims list for sign-off.pdf", contentType: "application/pdf",
                        missionNum: 4791, source: .item(num: 8667), postedAt: F.ago(2 * 86_400)),
            ProjectFile(blobID: "b3", name: "Hero flat-lay.jpg", contentType: "image/jpeg", missionNum: 4907,
                        source: .chat(convoID: "c1", seq: 40), postedAt: F.ago(6 * 86_400)),
        ])
        page.milestonesPage = ProjectFeedPage(total: 3, rows: [
            ProjectMilestone(milestone: Milestone(id: "ml_1", missionID: "ms_4907", num: 9001, kind: .progress,
                                                  title: "S7 confirmed: no Cloudflare rule caches HTML", convoID: "c1",
                                                  seq: 1, createdAt: F.ago(660)), missionNum: 4907),
            ProjectMilestone(milestone: Milestone(id: "ml_2", missionID: "ms_4907", num: 9002, kind: .userInput,
                                                  title: "Dan chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1",
                                                  seq: 2, createdAt: F.ago(13 * 3_600)), missionNum: 4907),
            ProjectMilestone(milestone: Milestone(id: "ml_3", missionID: "ms_4791", num: 9003, kind: .progress,
                                                  title: "Batch 4 pushed: the sales chat is on promo/integration",
                                                  convoID: "c1", seq: 3, createdAt: F.ago(14 * 3_600)), missionNum: 4791),
        ])
        page.hasFeed = true
        return page
    }

    private func detail(_ page: ProjectPageModel, loadingMore: Set<ProjectFeedKind> = []) -> some View {
        ProjectDetailView(page: page, now: F.now, loadingMore: loadingMore, onOpenMission: { _ in }, onOpenItem: { _ in },
                          onOpenSession: { _ in }, onOpenMilestone: { _ in }, onMoveMission: { _, _ in }, onRefresh: {})
    }

    /// A journal without the roll-up: today's page, "Latest steps" and all.
    func testProjectPagePhone() {
        assertVariants(of: detail(Self.page).frame(width: 390, height: 1_400), named: "project-page-phone")
    }

    /// The roll-up, with "Show all" on Decisions loading.
    func testProjectPagePhoneWithFeed() {
        assertVariants(of: detail(Self.pageWithFeed, loadingMore: [.decisions]).frame(width: 390, height: 2_200),
                       named: "project-page-phone-feed")
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

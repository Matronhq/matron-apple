import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectDetailSnapshotTests: XCTestCase {
    typealias F = ProjectsSnapshotTests

    static var page: ProjectPageModel {
        let branch = F.row(2171, "Search on the docs site: the index and the results page", activity: .waiting,
                           status: "Search works on staging; the changelog is not in the index yet.",
                           needsYou: 2, age: 660)
        let launch = F.row(2173, "Launch day: rehearsal, then the switch-over", activity: .running,
                           status: "Staging is green; the rehearsal is booked.", age: 660)
        var docs = F.docs
        docs = Project(id: docs.id, num: docs.num, title: docs.title,
                       body: "A new docs site with search, a getting-started guide and faster pages.",
                       status: docs.status, statusBy: docs.statusBy, statusUpdatedAt: docs.statusUpdatedAt,
                       missions: docs.missions, needsYou: docs.needsYou, lastActivityAt: docs.lastActivityAt)
        let asked = [TrackerItem(id: "it_1", num: 2301, kind: .question, awaiting: .user,
                                 title: "Getting-started copy: ship it with the launch?", originConvoID: "c1",
                                 createdAt: F.ago(2 * 3_600), updatedAt: F.ago(2 * 3_600), missionID: "ms_2171", missionNum: 2171),
                     TrackerItem(id: "it_2", num: 2302, kind: .question, awaiting: .user, title: "Which pages does search leave out?",
                                 originConvoID: "c1", createdAt: F.ago(26 * 3_600), updatedAt: F.ago(26 * 3_600),
                                 missionID: "ms_2173", missionNum: 2173)]
        return ProjectPageModel(
            project: docs,
            missions: [branch, launch],
            closedMissions: [Mission(id: "ms_c", num: 2150, state: .closed, title: "Old docs site", originConvoID: "c1")],
            needsYou: asked,
            openItems: asked + [TrackerItem(id: "it_3", num: 2311, kind: .task, awaiting: .agent, title: "Add the changelog to the search index",
                                            originConvoID: "c1", createdAt: F.ago(3_000), updatedAt: F.ago(3_000),
                                            missionID: "ms_2171", missionNum: 2171)],
            recentMilestones: [Milestone(id: "ml_1", missionID: "ms_2173", num: 2401, kind: .progress,
                                         title: "Every page loads in under a second on staging", convoID: "c1", seq: 1,
                                         createdAt: F.ago(660)),
                               Milestone(id: "ml_2", missionID: "ms_2173", num: 2402, kind: .userInput,
                                         title: "Alice chose a Wednesday morning launch", convoID: "c1", seq: 2,
                                         createdAt: F.ago(13 * 3_600))],
            missionNums: ["ms_2171": 2171, "ms_2173": 2173],
            sessionsByBox: ["slate": 2, "box-a": 1, "lab-mac": 1],
            sessionsByMission: ["ms_2171": [
                DashboardSession(id: "c-p", title: "docs-site owner", state: .waiting,
                                 tag: SessionTagInputs(boxLetter: "B", boxName: "box-a", sessionShort: "ad")),
                DashboardSession(id: "c-g", title: "search page", state: .running,
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
                DashboardSession(id: "c-d", title: "done one", state: .done, boxName: "aspen"),
            ]])
    }

    /// `page` with the journal's roll-up: an answered question, a reversed
    /// decision, files from an item and a chat, milestones over two days.
    static var pageWithFeed: ProjectPageModel {
        var page = Self.page
        page.decisions = ProjectFeedPage(total: 9, rows: [
            ProjectDecision(id: "it_d1", num: 2331, kind: .question, state: .closed, resolution: .answered,
                            title: "Approve the search results page for launch?", createdAt: F.ago(30 * 3_600),
                            closedAt: F.ago(20 * 3_600), missionNum: 2171, answer: "Yes, ship it."),
            ProjectDecision(id: "it_d2", num: 2332, kind: .decision, title: "Home shows the light theme as the app renders it",
                            createdAt: F.ago(3 * 86_400), missionNum: 2171),
            ProjectDecision(id: "it_d3", num: 2333, kind: .decision, state: .closed, resolution: .reversed,
                            title: "/help redirects to /start", createdAt: F.ago(4 * 86_400), missionNum: 2173),
        ], nextBefore: "cursor")
        page.files = ProjectFeedPage(total: 3, rows: [
            ProjectFile(blobID: "b1", name: "Search results desktop.png", contentType: "image/png", missionNum: 2171,
                        source: .item(num: 2301), postedAt: F.ago(86_400)),
            ProjectFile(blobID: "b2", name: "Home page wording for sign-off.pdf", contentType: "application/pdf",
                        missionNum: 2171, source: .item(num: 2302), postedAt: F.ago(2 * 86_400)),
            ProjectFile(blobID: "b3", name: "Hero guide on a desk.jpg", contentType: "image/jpeg", missionNum: 2173,
                        source: .chat(convoID: "c1", seq: 40), postedAt: F.ago(6 * 86_400)),
        ])
        page.milestonesPage = ProjectFeedPage(total: 3, rows: [
            ProjectMilestone(milestone: Milestone(id: "ml_1", missionID: "ms_2173", num: 2401, kind: .progress,
                                                  title: "Every page loads in under a second on staging", convoID: "c1",
                                                  seq: 1, createdAt: F.ago(660)), missionNum: 2173),
            ProjectMilestone(milestone: Milestone(id: "ml_2", missionID: "ms_2173", num: 2402, kind: .userInput,
                                                  title: "Alice chose a Wednesday morning launch", convoID: "c1",
                                                  seq: 2, createdAt: F.ago(13 * 3_600)), missionNum: 2173),
            ProjectMilestone(milestone: Milestone(id: "ml_3", missionID: "ms_2171", num: 2403, kind: .progress,
                                                  title: "The results page shows the section each page is in",
                                                  convoID: "c1", seq: 3, createdAt: F.ago(14 * 3_600)), missionNum: 2171),
        ])
        page.hasFeed = true
        return page
    }

    private func detail(_ page: ProjectPageModel, loadingMore: Set<ProjectFeedKind> = [],
                        expanded: Set<ProjectReferenceSection> = []) -> some View {
        ProjectDetailView(page: page, now: F.now, loadingMore: loadingMore, expanded: expanded,
                          onOpenMission: { _ in }, onOpenItem: { _ in },
                          onOpenSession: { _ in }, onOpenMilestone: { _ in }, onMoveMission: { _, _ in }, onRefresh: {})
    }

    /// A journal without the roll-up: the headline, Needs you, a Latest
    /// feed of the latest milestones and the open questions, the missions,
    /// the sessions fold.
    func testProjectPagePhone() {
        assertVariants(of: detail(Self.page).frame(width: 390, height: 1_400), named: "project-page-phone")
    }

    /// The roll-up: the merged feed (an answered question, a decision, a
    /// file, a question for you among the milestones), every reference
    /// section folded, "Show more" on Latest loading.
    func testProjectPagePhoneWithFeed() {
        assertVariants(of: detail(Self.pageWithFeed, loadingMore: [.decisions]).frame(width: 390, height: 1_900),
                       named: "project-page-phone-feed")
    }

    /// Every reference fold open.
    func testProjectPagePhoneFoldsOpen() {
        assertVariants(of: detail(Self.pageWithFeed, expanded: Set(ProjectReferenceSection.allCases))
                           .frame(width: 390, height: 2_600),
                       named: "project-page-phone-folds")
    }

    /// No status: the description takes the headline and there is no About fold.
    func testHeadlineFallsBackToTheDescription() {
        var page = Self.page
        page.project = Project(id: "pj_1", num: 2100, title: "Docs site launch", body: "The goal.")
        XCTAssertEqual(ProjectActivityFormat.headlineCaption(page.project, now: F.now), "ABOUT")
        XCTAssertEqual(ProjectActivityFormat.headlineText(page.project), "The goal.")
        XCTAssertFalse(ProjectReferenceSection.about.isShown(page))
        XCTAssertTrue(ProjectReferenceSection.about.isShown(Self.pageWithFeed))
        XCTAssertEqual(ProjectActivityFormat.headlineText(Project(id: "p", num: 1, title: "T")), "No written status yet")
        // A status of only whitespace counts as none, everywhere the page asks.
        let blank = Project(id: "p", num: 1, title: "T", body: "The goal.", status: "  \n")
        XCTAssertEqual(ProjectActivityFormat.headlineCaption(blank, now: F.now), "ABOUT")
        XCTAssertEqual(ProjectActivityFormat.headlineText(blank), "The goal.")
        XCTAssertFalse(ProjectActivityFormat.showsAboutFold(blank))
    }

    func testSessionRowMetaLine() {
        let m1 = Mission(id: "ms_1", num: 2171, title: "Docs search", originConvoID: "c1")
        let m2 = Mission(id: "ms_2", num: 2173, title: "Launch day", originConvoID: "c1")
        let stalled = DashboardSession(id: "c", title: "t", state: .waiting, model: "opus", isStalled: true)
        XCTAssertEqual(ProjectSessionRowView.metaLine(ProjectSessionRow(session: stalled, missions: [m1])),
                       "opus · stalled · #2171 Docs search")
        XCTAssertEqual(ProjectSessionRowView.metaLine(ProjectSessionRow(session: stalled, missions: [m1, m2])),
                       "opus · stalled · #2171, #2173")
        XCTAssertNil(ProjectSessionRowView.metaLine(ProjectSessionRow(
            session: DashboardSession(id: "c", title: "t", state: .done), missions: [])))
    }

    func testSessionChipLineCapsAtTwoAndCountsTheRest() {
        XCTAssertEqual(SessionChipLine.moreText(total: 3, limit: 2), "+1 more")
        XCTAssertNil(SessionChipLine.moreText(total: 2, limit: 2))
    }
}

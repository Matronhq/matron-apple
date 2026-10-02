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

    /// A current journal (Projects view v2): six projects with the card
    /// fields, every mission filed — so no slim-row sections at all.
    static var currentHome: ProjectsHomeSnapshot {
        func project(_ num: Int, _ title: String, status: String?, body: String = "",
                     missions: ProjectMissionCounts) -> Project {
            Project(id: "pj_\(num)", num: num, title: title, body: body, status: status, statusBy: .agent,
                    statusUpdatedAt: status == nil ? nil : F.ago(1_200), missions: missions, lastActivityAt: F.ago(600))
        }
        func waiting(_ num: Int, _ title: String, more: Int) -> ProjectWaitingOn {
            ProjectWaitingOn(itemID: "it_\(num)", num: num, kind: .question, title: title, more: more)
        }
        let cards = [
            ProjectCard(project: project(4100, "Shipping labels for individual books", status:
                "Royal Mail July prices are live on production through ship-yourself 1.0.18. The orders-table redesign and the FedEx/DHL connectors are built but wait on four answers from you: carrier emails to Harrier and Royal Mail, exact packaging sizes, and the hoodie carton.",
                missions: ProjectMissionCounts(running: 1, waiting: 1)), needsYouCount: 4,
                waitingOn: waiting(3432, "Send Harrier the manifesting / collection / return address email", more: 3),
                sessionsNow: 14),
            ProjectCard(project: project(4000, "Promo site launch on 7 Oct", status:
                "On track for Wed 7 Oct, 07:00 (fallback Tue 13 Oct). The branch is complete and green with the sales chat merged; Cloudflare and deploy-1 are briefed for Monday's rehearsal. Two approvals from you gate Sunday's checkpoint.",
                missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1)), needsYouCount: 2,
                waitingOn: waiting(5008, "Approve the leavers' books page (copy and pictures)", more: 1), sessionsNow: 9),
            ProjectCard(project: project(4200, "Templates customer-ready", status:
                "Titles, polls, contents and dividers are shipped for all 15 families. Profiles (phase 2C) are in the InDesign queue now: Waves, then Torn Paper, then book colours. Articles and montages (2D) start once the Mac is free.",
                missions: ProjectMissionCounts(running: 3, waiting: 1, idle: 2)), needsYouCount: 2,
                waitingOn: waiting(5969, "Merge approval for two template fixes in greg's train", more: 1), sessionsNow: 7),
            ProjectCard(project: project(4300, "Call system pilot", status:
                "Twilio production is set up and every secret is sealed. The softphone's first TestFlight build is ready; the app PRs deploy in tonight's batch. Customer calls wait on the privacy-policy rewrite.",
                missions: ProjectMissionCounts(running: 2, waiting: 1)), needsYouCount: 2,
                waitingOn: waiting(5752, "Apple ID emails for Jack, Christina and Kitty (TestFlight)", more: 1), sessionsNow: 4),
            ProjectCard(project: project(4400, "Crest digitizer good enough to approve", status:
                "Logo set 1311 passes acceptance on the production build (QA 0.72, no errors), so Approve is your click. Separately, the stroke-alphabet lettering is being refined: joins into round letters and the S are next.",
                missions: ProjectMissionCounts(running: 1, waiting: 1)), needsYouCount: 1,
                waitingOn: waiting(5882, "Redrawn letters on by default, or per crest?", more: 0), sessionsNow: 2),
            ProjectCard(project: project(4500, "File storage on ZFS + Gluster", status: nil,
                body: "The per-book storage cutover is live: 125 books moved to Gluster with none failed, and backups are current. Now building the read-only production query box on shared-3, after you approved all five design calls.",
                missions: ProjectMissionCounts(running: 2, idle: 2)),
                latest: ProjectLatest(title: "PR opened with the cookbook, role, environment and replica firewall rule",
                                      kind: .progress, at: F.ago(45 * 60)),
                sessionsNow: 5),
        ]
        return ProjectsHomeSnapshot(cards: cards, statusRefreshedAt: F.ago(1_200))
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

    func testCardColumnsFollowThePageWidthOnTheMac() {
        #if os(macOS)
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 0), 1, "before the first layout")
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 647), 1)
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 648), 2, "two 300s, the gap and the padding")
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 728), 2, "the narrowest window")
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 963), 2)
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 964), 3)
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 1_208), 3, "the default window")
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 1_440), 4)
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 2_400), 7)
        #else
        XCTAssertEqual(ProjectsHomeView.cardColumnCount(pageWidth: 1_024), 1)
        #endif
    }

    func testHomeEmpty() {
        assertVariants(of: page(ProjectsHomeSnapshot()).frame(width: 390, height: 360), named: "projects-home-empty")
    }

    func testHomePhoneWidth() {
        assertVariants(of: page(Self.home).frame(width: 390, height: 1_500), named: "projects-home-phone")
    }

    /// An older journal: unfiled and quiet missions still show, under
    /// cards without the v2 fields.
    func testHomeMacWidth() {
        assertVariants(of: page(Self.home).frame(width: 1_280, height: 1_400), named: "projects-home-wide")
    }

    /// The Mac page at 1440 pt on a current journal: four columns of
    /// cards, each with its waiting-on or latest box, and nothing else.
    func testHomeCurrentJournal1440() {
        assertVariants(of: page(Self.currentHome).frame(width: 1_440, height: 1_200), named: "projects-home-1440")
    }

    /// The Mac window at its default size (1280 × 860), less the 72 pt
    /// nav column and the title bar: three columns.
    func testHomeCurrentJournalDefaultWindow() {
        assertVariants(of: page(Self.currentHome).frame(width: 1_208, height: 800), named: "projects-home-default-window")
    }

    func testNewProjectSheet() {
        assertVariants(of: NewProjectSheet(onCreate: { _, _ in nil }, onCancel: {}).frame(width: 440),
                       named: "projects-new-sheet")
    }

    /// Review M9: over 200 characters, the sheet says why Create is disabled.
    func testNewProjectSheetTitleTooLong() {
        assertVariants(of: NewProjectSheet(title: String(repeating: "a", count: 201), onCreate: { _, _ in nil },
                                           onCancel: {}).frame(width: 440),
                       named: "projects-new-sheet-too-long")
    }
}

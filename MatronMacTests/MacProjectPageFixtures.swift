#if os(macOS)
import Foundation
@testable import MatronMac
import MatronModels

/// A made-up "Docs site launch" project, at a fixed `now`.
enum MacProjectPageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static func row(_ num: Int, _ title: String, _ status: String?, _ activity: MissionActivity, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "Search page merged…",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status, projectID: "pj_1"),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    static func item(_ num: Int, _ title: String, mission: Int, kind: ItemKind = .question,
                     awaiting: ItemAwaiting? = .user, age: TimeInterval = 0) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, awaiting: awaiting, title: title, originConvoID: "c1",
                    createdAt: ago(age + 3_600), updatedAt: ago(age), missionID: "ms_\(mission)", missionNum: mission)
    }

    static let needsYou = [item(2301, "Getting-started copy: ship it with the launch?", mission: 2171),
                           item(2302, "Approve the wording on the home page", mission: 2171),
                           item(2303, "Which pages does search leave out?", mission: 2173)]

    /// Ten items Needs you does not show: more than the fold's eight.
    static let otherItems: [TrackerItem] = [
        item(2311, "Add the changelog to the search index", mission: 2171, kind: .task, awaiting: .agent, age: 600),
        item(2312, "Re-check the old links after the switch-over", mission: 2171, kind: .task, awaiting: .agent, age: 7_200),
        item(2313, "Keep the new site on staging until launch", mission: 2171, kind: .decision, awaiting: nil, age: 90_000),
        item(2314, "Try search on a phone before launch", mission: 2173, kind: .task, awaiting: .agent, age: 300),
        item(2315, "Launch checklist: check every redirect", mission: 2173, kind: .task, awaiting: .agent, age: 4_000),
        item(2316, "A second launch day is set aside", mission: 2173, kind: .decision, awaiting: nil, age: 50_000),
        item(2317, "After launch: watch for broken links for a day", mission: 2173, kind: .task, awaiting: nil, age: 60_000),
        item(2318, "List the pages still to move", mission: 2172, kind: .task, awaiting: .agent, age: 86_400),
        item(2319, "Report back on what is left", mission: 2172, kind: .task, awaiting: .agent, age: 90_000),
        item(2320, "Delete the old page images", mission: 2172, kind: .task, awaiting: nil, age: 100_000),
    ]

    /// The current project — open, so it is one of its own "Move to…" targets
    /// (`ProjectDetailViewModel.rebuild()`: `moveTargets` is every open
    /// project, not gated the way `mergeTargets`/`unfiledMissions` are).
    static let project = Project(id: "pj_1", num: 2100, title: "Docs site launch",
                                 body: "A new docs site with search, a getting-started guide and faster pages.",
                                 status: "Launch on Wednesday at 07:00, after a rehearsal on Monday. Search works on staging and pages load in under a second.",
                                 statusBy: .agent, statusUpdatedAt: ago(660),
                                 missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1), needsYou: 6, openItems: 43)
    static let otherOpenProject = Project(id: "pj_2", num: 2101, title: "Matron apps")

    static let page = ProjectPageModel(
        project: project,
        missions: [
            row(2171, "Search on the docs site: the index and the results page",
                "Search works on staging; the changelog is not in the index yet.", .waiting, needsYou: 2, age: 660),
            row(2173, "Launch day: rehearsal, then the switch-over", "Staging is green; the rehearsal is booked.", .running, age: 660),
            row(2172, "Move the old pages across: list and report", nil, .idle, age: 86_400),
        ],
        needsYou: needsYou,
        openItems: needsYou + otherItems,
        recentMilestones: [
            Milestone(id: "ml_1", missionID: "ms_2173", num: 2401, kind: .progress,
                      title: "Every page loads in under a second on staging", convoID: "c1", seq: 1, createdAt: ago(660)),
            Milestone(id: "ml_2", missionID: "ms_2173", num: 2402, kind: .userInput,
                      title: "Alice chose a Wednesday morning launch", convoID: "c1", seq: 2, createdAt: ago(13 * 3_600)),
        ],
        missionNums: ["ms_2171": 2171, "ms_2173": 2173, "ms_2172": 2172],
        sessionsByBox: ["slate": 2, "box-a": 1, "lab-mac": 1, "reef": 1, "aspen": 1],
        sessionsByMission: [
            "ms_2173": [
                DashboardSession(id: "c-g", title: "search page", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
                DashboardSession(id: "c-d", title: "redirects", state: .running, lastActivity: ago(600),
                                 tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "16"),
                                 model: "sonnet", context: SessionStatus.Context(tokens: 88_000, window: 200_000, pct: 44)),
                DashboardSession(id: "c-x", title: "old", state: .done, boxName: "aspen"),
            ],
            "ms_2171": [
                DashboardSession(id: "c-p", title: "docs-site owner", state: .waiting, lastActivity: ago(660),
                                 tag: SessionTagInputs(boxLetter: "B", boxName: "box-a", sessionShort: "ad"),
                                 model: "opus", context: SessionStatus.Context(tokens: 912_000, window: 1_000_000, pct: 91),
                                 isStalled: true),
                DashboardSession(id: "c-g2", title: "page migration", state: .waiting, lastActivity: ago(3_000),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "2f"), model: "opus"),
                DashboardSession(id: "c-g", title: "search page", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
            ],
        ],
        mergeTargets: [otherOpenProject],
        moveTargets: [project, otherOpenProject],
        unfiledMissions: [Mission(id: "ms_2190", num: 2190, title: "Translate the docs", originConvoID: "c1")])

    // MARK: Projects view v2 roll-up

    static func decision(_ num: Int, _ title: String, mission: Int, age: TimeInterval, kind: ItemKind = .decision,
                         resolution: ItemResolution? = nil, answer: String? = nil) -> ProjectDecision {
        let closed = kind == .question || resolution != nil
        return ProjectDecision(id: "it_\(num)", num: num, kind: kind, state: closed ? .closed : .open,
                               resolution: kind == .question ? .answered : resolution, title: title,
                               createdAt: ago(age + 3_600), closedAt: closed ? ago(age) : nil,
                               missionID: "ms_\(mission)", missionNum: mission, answer: answer)
    }

    /// Newest first: an answered question, decisions, a reversed one.
    static let decisions = ProjectFeedPage(total: 23, rows: [
        decision(2331, "Approve the search results page: titles, a short extract, and the section each page is in",
                 mission: 2160, age: 11 * 3_600, kind: .question, answer: "Yes, ship it. Put the section first."),
        decision(2332, "Home \"How it works\": 2 single steps + 2 swipeable groups, smaller shots, phone browser bar",
                 mission: 2160, age: 3 * 86_400),
        decision(2333, "Home: screenshots show the light theme as the app renders it, not the hero's navy",
                 mission: 2160, age: 3 * 86_400 + 600),
        decision(2334, "Launch on Wednesday morning, or wait for the changelog?", mission: 2173, age: 4 * 86_400,
                 kind: .question, answer: "Wednesday. The changelog can follow."),
        decision(2335, "/help redirects to /start", mission: 2171, age: 4 * 86_400 + 900, resolution: .reversed),
        decision(2336, "/help redirects to /guide#help", mission: 2171, age: 4 * 86_400 + 600, resolution: .decided),
        decision(2337, "Examples links held back: those pages are still placeholders", mission: 2171, age: 5 * 86_400),
    ], nextBefore: "1799500000000:it_2337")

    static func file(_ blob: String, _ name: String, _ type: String, _ source: ProjectFileSource,
                     age: TimeInterval) -> ProjectFile {
        ProjectFile(blobID: blob, name: name, contentType: type, source: source, postedAt: ago(age))
    }

    static let files = ProjectFeedPage(total: 37, rows: [
        file("b1", "Search results, desktop.png", "image/png", .item(num: 2301), age: 86_400),
        file("b2", "Search results, phone.png", "image/png", .item(num: 2301), age: 90_000),
        file("b3", "Home page wording for sign-off.pdf", "application/pdf", .item(num: 2302), age: 2 * 86_400),
        file("b4", "How it works, 4 steps.png", "image/png", .chat(convoID: "c-reef", seq: 812), age: 5 * 86_400),
        file("b5", "Hero: guide on a desk.jpg", "image/jpeg", .item(num: 2338), age: 6 * 86_400),
        file("b6", "Launch checklist.csv", "text/csv", .chat(convoID: "c-reef", seq: 640), age: 6 * 86_400 + 600),
    ], nextBefore: "1799400000000:b6")

    static func milestone(_ num: Int, _ title: String, mission: Int, age: TimeInterval,
                          kind: MilestoneKind = .progress) -> ProjectMilestone {
        ProjectMilestone(milestone: Milestone(id: "ml_\(num)", missionID: "ms_\(mission)", num: num, kind: kind,
                                              title: title, convoID: "c1", seq: Int64(num), createdAt: ago(age)),
                         missionNum: mission)
    }

    /// Two days: this morning, and yesterday evening. (`now` is 08:00 UTC.)
    static let milestones = ProjectFeedPage(total: 151, rows: [
        milestone(2405, "Morning check: staging is green; only Alice's two approvals come before Monday's rehearsal",
                  mission: 2173, age: 6 * 60),
        milestone(2404, "Search page merged: tests, review and the staging check all pass",
                  mission: 2173, age: 10 * 3_600 + 56 * 60),
        milestone(2403, "The search index now covers every guide page",
                  mission: 2171, age: 10 * 3_600 + 57 * 60),
        milestone(2402, "The results page shows the section each page is in",
                  mission: 2171, age: 12 * 3_600 + 12 * 60),
        milestone(2401, "Alice: search covers the guides and the reference; the blog stays out",
                  mission: 2160, age: 14 * 3_600 + 58 * 60, kind: .userInput),
    ], nextBefore: "1799946000000:ml_2401")

    /// `page` as a journal with the roll-up sends it, one closed mission
    /// in the fold.
    static var pageWithFeed: ProjectPageModel {
        var page = page
        page.project = Project(id: project.id, num: project.num, title: "Docs site launch on Wednesday",
                               body: "Done when the new docs site is live on example.com and the launch checklist is complete. Launch needs your go on the day; a second day is set aside.",
                               status: "On track for Wednesday at 07:00. Search works on staging, pages load in under a second, and the getting-started guide is drafted. Your approvals of the guide's copy and the home page wording come before Monday's rehearsal; the go-ahead question follows on Tuesday.",
                               statusBy: .agent, statusUpdatedAt: ago(1_200),
                               missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1, closed: 1), needsYou: 3,
                               openItems: 13, lastActivityAt: ago(6 * 60))
        page.closedMissions = [Mission(id: "ms_2150", num: 2150, state: .closed, title: "Fix the broken anchor links",
                                       closeSummary: "Fixed and checked on staging.", originConvoID: "c1", closedAt: ago(9 * 86_400))]
        page.decisions = decisions
        page.files = files
        page.milestonesPage = milestones
        page.hasFeed = true
        return page
    }
}
#endif

#if os(macOS)
import Foundation
@testable import MatronMac
import MatronModels

/// The "Promo launch" project of mockup 02, at a fixed `now`.
enum MacProjectPageFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static func row(_ num: Int, _ title: String, _ status: String?, _ activity: MissionActivity, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "PR 8601 merged…",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status, projectID: "pj_1"),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    static func item(_ num: Int, _ title: String, mission: Int, kind: ItemKind = .question,
                     awaiting: ItemAwaiting? = .user, age: TimeInterval = 0) -> TrackerItem {
        TrackerItem(id: "it_\(num)", num: num, kind: kind, awaiting: awaiting, title: title, originConvoID: "c1",
                    updatedAt: ago(age), missionID: "ms_\(mission)", missionNum: mission)
    }

    static let needsYou = [item(8666, "Pricing page PR 8666 — ship with launch?", mission: 4791),
                           item(8667, "Claims on the homepage copy", mission: 4791),
                           item(8668, "Cloudflare: page rule for /blog", mission: 4907)]

    /// Ten items Needs you does not show: more than the fold's eight.
    static let otherItems: [TrackerItem] = [
        item(8701, "Infra PR 605: blog nginx line", mission: 4791, kind: .task, awaiting: .agent, age: 600),
        item(8702, "Re-run the R2 redirect check after deploy", mission: 4791, kind: .task, awaiting: .agent, age: 7_200),
        item(8703, "Keep /proto behind basic auth until launch", mission: 4791, kind: .decision, awaiting: nil, age: 90_000),
        item(8704, "Smoke-test the sales chat on staging", mission: 4907, kind: .task, awaiting: .agent, age: 300),
        item(8705, "Launch checklist: DNS TTLs down to 300", mission: 4907, kind: .task, awaiting: .agent, age: 4_000),
        item(8706, "Fallback date is 13 Oct", mission: 4907, kind: .decision, awaiting: nil, age: 50_000),
        item(8707, "Post-launch: watch 404s for a day", mission: 4907, kind: .task, awaiting: nil, age: 60_000),
        item(8708, "Gather the branch's open PRs", mission: 4083, kind: .task, awaiting: .agent, age: 86_400),
        item(8709, "Report back on merge order", mission: 4083, kind: .task, awaiting: .agent, age: 90_000),
        item(8710, "Drop the old promo assets", mission: 4083, kind: .task, awaiting: nil, age: 100_000),
    ]

    /// The current project — open, so it is one of its own "Move to…" targets
    /// (`ProjectDetailViewModel.rebuild()`: `moveTargets` is every open
    /// project, not gated the way `mergeTargets`/`unfiledMissions` are).
    static let project = Project(id: "pj_1", num: 4000, title: "Promo launch",
                                 body: "New promo site, blog, pricing page and sales chat, launched from promo/integration.",
                                 status: "Launch Wed 7 Oct, 07:00 (fallback 13 Oct; checkpoint Sun 4 Oct 18:00). The branch meets the launch gate.",
                                 statusBy: .agent, statusUpdatedAt: ago(660),
                                 missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1), needsYou: 6, openItems: 43)
    static let otherOpenProject = Project(id: "pj_2", num: 4001, title: "Matron apps")

    static let page = ProjectPageModel(
        project: project,
        missions: [
            row(4791, "Promo branch: /proto design at the base URLs",
                "R2 redirect test done on 328 addresses; infra PR 605 needs the blog nginx line.", .waiting, needsYou: 2, age: 660),
            row(4907, "Launch day: Wed 7 Oct 07:00", "Branch green at b6794bffa8; S7 confirmed.", .running, age: 660),
            row(4083, "Combined promo branch: gather and report", nil, .idle, age: 86_400),
        ],
        needsYou: needsYou,
        openItems: needsYou + otherItems,
        recentMilestones: [
            Milestone(id: "ml_1", missionID: "ms_4907", num: 9001, kind: .progress,
                      title: "S7 confirmed: no Cloudflare rule caches HTML", convoID: "c1", seq: 1, createdAt: ago(660)),
            Milestone(id: "ml_2", missionID: "ms_4907", num: 9002, kind: .userInput,
                      title: "Alice chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1", seq: 2, createdAt: ago(13 * 3_600)),
        ],
        missionNums: ["ms_4791": 4791, "ms_4907": 4907, "ms_4083": 4083],
        sessionsByBox: ["slate": 2, "pat": 1, "lab-mac": 1, "reef": 1, "aspen": 1],
        sessionsByMission: [
            "ms_4907": [
                DashboardSession(id: "c-g", title: "sales-chat", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
                DashboardSession(id: "c-d", title: "Cloudflare", state: .running, lastActivity: ago(600),
                                 tag: SessionTagInputs(boxLetter: "L", boxName: "lab-mac", sessionShort: "16"),
                                 model: "sonnet", context: SessionStatus.Context(tokens: 88_000, window: 200_000, pct: 44)),
                DashboardSession(id: "c-x", title: "old", state: .done, boxName: "aspen"),
            ],
            "ms_4791": [
                DashboardSession(id: "c-p", title: "promo/integration owner", state: .waiting, lastActivity: ago(660),
                                 tag: SessionTagInputs(boxLetter: "P", boxName: "pat", sessionShort: "ad"),
                                 model: "opus", context: SessionStatus.Context(tokens: 912_000, window: 1_000_000, pct: 91),
                                 isStalled: true),
                DashboardSession(id: "c-g2", title: "blog migration", state: .waiting, lastActivity: ago(3_000),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "2f"), model: "opus"),
                DashboardSession(id: "c-g", title: "sales-chat", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "S", boxName: "slate", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
            ],
        ],
        mergeTargets: [otherOpenProject],
        moveTargets: [project, otherOpenProject],
        unfiledMissions: [Mission(id: "ms_5148", num: 5148, title: "Convert to editor v2", originConvoID: "c1")])

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
        decision(8690, "Approve the sales chat for launch: answers questions about plans and billing, hands off to support",
                 mission: 2407, age: 11 * 3_600, kind: .question, answer: "Yes, ship it with the chat on. Support answers from 9 to 5."),
        decision(8691, "Home \"How it works\": 2 single beats + 2 swipeable groups, smaller shots, phone browser bar",
                 mission: 2407, age: 3 * 86_400),
        decision(8692, "Home: product screenshots show the Blue theme as the app renders it, not the hero's navy",
                 mission: 2407, age: 3 * 86_400 + 600),
        decision(8693, "Launch date: Wed 7 Oct at 07:00, or wait for the blog?", mission: 4907, age: 4 * 86_400,
                 kind: .question, answer: "7 Oct. The blog can follow."),
        decision(8694, "/contacts redirects to /product", mission: 4791, age: 4 * 86_400 + 900, resolution: .reversed),
        decision(8695, "/contacts redirects to /about#contact", mission: 4791, age: 4 * 86_400 + 600, resolution: .decided),
        decision(8696, "Stories links held back: /case-studies is placeholder content", mission: 4791, age: 5 * 86_400),
    ], nextBefore: "1799500000000:it_8696")

    static func file(_ blob: String, _ name: String, _ type: String, _ source: ProjectFileSource,
                     age: TimeInterval) -> ProjectFile {
        ProjectFile(blobID: blob, name: name, contentType: type, source: source, postedAt: ago(age))
    }

    static let files = ProjectFeedPage(total: 37, rows: [
        file("b1", "Pricing page, desktop.png", "image/png", .item(num: 5008), age: 86_400),
        file("b2", "Pricing page, phone.png", "image/png", .item(num: 5008), age: 90_000),
        file("b3", "Claims list for sign-off.pdf", "application/pdf", .item(num: 5090), age: 2 * 86_400),
        file("b4", "How it works, 4 beats.png", "image/png", .chat(convoID: "c-reef", seq: 812), age: 5 * 86_400),
        file("b5", "Hero: slate flat-lay.jpg", "image/jpeg", .item(num: 2915), age: 6 * 86_400),
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
        milestone(9101, "Thu 1 Oct sweep: branch complete and green; only Alice's two approvals gate the Sunday checkpoint",
                  mission: 4907, age: 6 * 60),
        milestone(9100, "Branch complete and green with the chat merged: a2e29634ef, CI, review, zero threads, mergeable",
                  mission: 4907, age: 10 * 3_600 + 56 * 60),
        milestone(9099, "Head a2e29634ef green on all six CI jobs and review: the sales chat is on the branch",
                  mission: 4791, age: 10 * 3_600 + 57 * 60),
        milestone(9098, "Batch 4 pushed: the sales chat (PR 8560) and a fourth master merge are on promo/integration",
                  mission: 4791, age: 12 * 3_600 + 12 * 60),
        milestone(9097, "Alice: the chat answers plans and billing only; anything about a specific account goes to support",
                  mission: 2407, age: 14 * 3_600 + 58 * 60, kind: .userInput),
    ], nextBefore: "1799946000000:ml_9097")

    /// `page` as a journal with the roll-up sends it, one closed mission
    /// in the fold.
    static var pageWithFeed: ProjectPageModel {
        var page = page
        page.project = Project(id: project.id, num: project.num, title: "Promo site launch on 7 Oct",
                               body: "Done when the new promo site is live on example.com and the launch checklist is complete. Launch needs your go on the day; fallback 13 Oct.",
                               status: "On track for Wed 7 Oct, 07:00 (fallback Tue 13 Oct). The branch is complete and green with the sales chat merged; Cloudflare and ship-box are briefed for Monday's rehearsal. Your approvals of the pricing page and the site's claims gate Sunday's 18:00 checkpoint; the final master merge and the go-ahead question follow on Tuesday.",
                               statusBy: .agent, statusUpdatedAt: ago(1_200),
                               missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 1, closed: 1), needsYou: 3,
                               openItems: 13, lastActivityAt: ago(6 * 60))
        page.closedMissions = [Mission(id: "ms_1758", num: 1758, state: .closed, title: "Reword the trial-length copy",
                                       closeSummary: "Shipped in PR 8420.", originConvoID: "c1", closedAt: ago(9 * 86_400))]
        page.decisions = decisions
        page.files = files
        page.milestonesPage = milestones
        page.hasFeed = true
        return page
    }
}
#endif

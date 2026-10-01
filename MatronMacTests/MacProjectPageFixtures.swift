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

    static let needsYou = [item(8666, "Leavers' page PR 8666 — ship with launch?", mission: 4791),
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
                                 body: "New promo site, blog, leavers' page and sales chat, launched from promo/integration.",
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
                      title: "Dan chose Wed 7 Oct, 07:00, fallback 13 Oct", convoID: "c1", seq: 2, createdAt: ago(13 * 3_600)),
        ],
        missionNums: ["ms_4791": 4791, "ms_4907": 4907, "ms_4083": 4083],
        sessionsByBox: ["greg": 2, "pat": 1, "dan-mac": 1, "terry": 1, "bev": 1],
        sessionsByMission: [
            "ms_4907": [
                DashboardSession(id: "c-g", title: "sales-chat", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
                DashboardSession(id: "c-d", title: "Cloudflare", state: .running, lastActivity: ago(600),
                                 tag: SessionTagInputs(boxLetter: "D", boxName: "dan-mac", sessionShort: "16"),
                                 model: "sonnet", context: SessionStatus.Context(tokens: 88_000, window: 200_000, pct: 44)),
                DashboardSession(id: "c-x", title: "old", state: .done, boxName: "bev"),
            ],
            "ms_4791": [
                DashboardSession(id: "c-p", title: "promo/integration owner", state: .waiting, lastActivity: ago(660),
                                 tag: SessionTagInputs(boxLetter: "P", boxName: "pat", sessionShort: "ad"),
                                 model: "opus", context: SessionStatus.Context(tokens: 912_000, window: 1_000_000, pct: 91),
                                 isStalled: true),
                DashboardSession(id: "c-g2", title: "blog migration", state: .waiting, lastActivity: ago(3_000),
                                 tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "2f"), model: "opus"),
                DashboardSession(id: "c-g", title: "sales-chat", state: .running, lastActivity: ago(120),
                                 tag: SessionTagInputs(boxLetter: "G", boxName: "greg", sessionShort: "13"),
                                 model: "opus", context: SessionStatus.Context(tokens: 265_000, window: 1_000_000, pct: 27)),
            ],
        ],
        mergeTargets: [otherOpenProject],
        moveTargets: [project, otherOpenProject],
        unfiledMissions: [Mission(id: "ms_5148", num: 5148, title: "Convert to editor v2", originConvoID: "c1")])
}
#endif

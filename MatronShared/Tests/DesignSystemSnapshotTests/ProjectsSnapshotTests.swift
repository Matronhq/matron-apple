import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ProjectsSnapshotTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
    static let utc = TimeZone(identifier: "UTC")!

    static let promo = Project(
        id: "pj_1", num: 4000, title: "Promo launch", status:
            "Launch Wed 7 Oct, 07:00 (fallback 13 Oct). The branch is green. Waiting on you: leavers' page, claims copy, Cloudflare.",
        statusBy: .agent, statusUpdatedAt: ago(660),
        missions: ProjectMissionCounts(running: 2, waiting: 2, idle: 0, quiet: 1, closed: 3), needsYou: 6,
        lastActivityAt: ago(240))
    static let silent = Project(
        id: "pj_2", num: 4001, title: "Sales tax & bulk payments",
        missions: ProjectMissionCounts(quiet: 6), lastActivityAt: ago(2 * 86_400))

    static func row(_ num: Int, _ title: String, activity: MissionActivity, status: String?, needsYou: Int = 0,
                    age: TimeInterval) -> MissionRowModel {
        MissionRowModel(mission: Mission(id: "ms_\(num)", num: num, title: title, originConvoID: "c1",
                                         lastMilestone: MissionLastMilestone(num: num + 1, title: "PR 8601 merged",
                                                                             kind: .progress, createdAt: ago(86_400)),
                                         status: status),
                        activity: activity, needsYouCount: needsYou, lastActivity: ago(age))
    }

    // MARK: Pure

    func testCountsLine() {
        XCTAssertEqual(ProjectsFormat.countsLine(Self.promo.missions, statusUpdatedAt: Self.ago(660),
                                                 lastActivityAt: Self.ago(240), now: Self.now),
                       "5 missions · 2 running · 2 waiting · 1 quiet · updated 11m ago")
        XCTAssertEqual(ProjectsFormat.countsLine(Self.silent.missions, statusUpdatedAt: nil,
                                                 lastActivityAt: Self.ago(2 * 86_400), now: Self.now),
                       "6 missions · all quiet · last activity 2d ago")
        XCTAssertEqual(ProjectsFormat.countsLine(ProjectMissionCounts(running: 1), statusUpdatedAt: nil,
                                                 lastActivityAt: nil, now: Self.now),
                       "1 mission · 1 running")
    }

    func testStatusHeadingNeverSaysNowAgoOrDateAgo() {
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: nil, now: Self.now), "STATUS")
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: Self.ago(30), now: Self.now), "STATUS · just now")
        XCTAssertEqual(ProjectsFormat.statusHeading(updatedAt: Self.ago(1_200), now: Self.now), "STATUS · 20m ago")
        let old = ProjectsFormat.statusHeading(updatedAt: Self.ago(8 * 86_400), now: Self.now)
        XCTAssertTrue(old.hasPrefix("STATUS · on "), old)
        XCTAssertFalse(old.hasSuffix(" ago"), old)
    }

    func testNoStatusAndMissionLines() {
        XCTAssertEqual(ProjectsFormat.noStatusLine(latest: nil, now: Self.now), "No written status yet")
        XCTAssertEqual(ProjectsFormat.noStatusLine(
            latest: MissionLastMilestone(num: 1, title: "PR 8270 final", kind: .progress, createdAt: Self.ago(3 * 3_600)),
            now: Self.now), "No written status yet — latest: “PR 8270 final” (3h ago)")
        let noStatus = Self.row(4083, "Combined promo branch", activity: .idle, status: nil, age: 86_400).mission
        XCTAssertEqual(ProjectsFormat.missionLine(noStatus, now: Self.now),
                       "No status · last milestone 1d ago: “PR 8601 merged”")
        let multi = Self.row(1, "T", activity: .idle, status: "Line one.\nLine two.", age: 60).mission
        XCTAssertEqual(ProjectsFormat.missionLine(multi, now: Self.now), "Line one. Line two.")
    }

    func testLinkWording() {
        let d29 = Date(timeIntervalSince1970: 1_759_104_000) // 29 Sep 2025 00:00 UTC
        let d30 = d29.addingTimeInterval(86_400)
        XCTAssertEqual(ProjectsFormat.shortDate(d29, timeZone: Self.utc), "29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "origin", timeZone: Self.utc),
                       "since 29 Sep (started this mission)")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: nil, how: "joined", timeZone: Self.utc), "joined 29 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: d29, endedAt: d30, how: "joined", timeZone: Self.utc), "29 Sep → 30 Sep")
        XCTAssertEqual(ProjectsFormat.linkSpan(joinedAt: nil, endedAt: nil, how: nil, timeZone: Self.utc), "")
        let mission = Mission(id: "ms_1", num: 1, title: "M", originConvoID: "c1")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isCurrent: true, joinedAt: d29),
                                                 timeZone: Self.utc), "Current · since 29 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, joinedAt: d30),
                                                 timeZone: Self.utc), "Also on · joined 30 Sep")
        XCTAssertEqual(ProjectsFormat.headerLine(ConversationMissionLink(mission: mission, isActive: false, joinedAt: d29,
                                                                         endedAt: d30), timeZone: Self.utc), "29 Sep → 30 Sep")
    }

    func testSessionsByBoxAndConversationSummary() {
        XCTAssertEqual(ProjectsFormat.sessionsByBox(["pat": 1, "greg": 2, "bev": 1]), "greg 2 · bev 1 · pat 1")
        let groups = MissionConversationGroups(conversations: [
            MissionConversation(id: "c1", title: "a", box: nil, state: "running", subchatCount: 6),
            MissionConversation(id: "c2", title: "b", box: nil, state: "done", endedAt: Self.ago(60)),
        ], missionState: .open)
        XCTAssertEqual(ProjectsFormat.conversationsSummary(groups), "1 on it now · 1 earlier · 6 sub-chats folded")
    }

    func testLinkedMissionChipOpensItsMission() {
        var opened: String?
        let chip = LinkedMissionChip(linked: .movedTo(MissionOtherLink(id: "ms_4905", num: 4905, title: "SEO phase 2"))) {
            opened = "ms_4905"
        }
        chip.action()
        XCTAssertEqual(opened, "ms_4905")
        XCTAssertEqual(LinkedMissionChip.accessibilityText(.alsoOn(MissionOtherLink(id: "ms_1", num: 4791, title: "Promo"))),
                       "also on mission 4791, Promo")
    }

    // MARK: Snapshots

    func testLinkedMissionChips() {
        let chips = VStack(alignment: .leading, spacing: 8) {
            LinkedMissionChip(linked: .alsoOn(MissionOtherLink(id: "ms_4791", num: 4791, title: "Promo branch")), action: {})
            LinkedMissionChip(linked: .movedTo(MissionOtherLink(id: "ms_4905", num: 4905, title: "SEO phase 2")), action: {})
        }
        assertVariants(of: chips.padding(), named: "linked-mission-chips")
    }

    func testProjectCardWithStatus() {
        assertVariants(of: ProjectCardView(card: ProjectCard(project: Self.promo, needsYouCount: 6), now: Self.now, onOpen: {})
            .frame(width: 380).padding(), named: "project-card-status")
    }

    func testProjectCardWithoutStatus() {
        let card = ProjectCard(project: Self.silent, needsYouCount: 1,
                               latestMilestone: MissionLastMilestone(num: 9, title: "PR 8270 final at ae015adc9c",
                                                                     kind: .progress, createdAt: Self.ago(12 * 86_400)))
        assertVariants(of: ProjectCardView(card: card, now: Self.now, onOpen: {}).frame(width: 380).padding(),
                       named: "project-card-no-status")
    }

    func testMissionRows() {
        let rows = VStack(spacing: 0) {
            MissionRowView(row: Self.row(5148, "Convert to editor v2: conversion status + email + Slack", activity: .running,
                                         status: "PR 8686 open; waiting on CI and Bugbot, then the merge train.", age: 240),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(3170, "Sample book proof feedback for Jack", activity: .waiting,
                                         status: "Pages 4–41 done; waiting on you to dictate the rest.", needsYou: 1, age: 300),
                           now: Self.now)
            Divider()
            MissionRowView(row: Self.row(4083, "Combined promo branch: gather and report", activity: .idle,
                                         status: nil, age: 86_400), now: Self.now)
        }
        assertVariants(of: rows.frame(width: 720).padding(), named: "mission-rows")
    }
}

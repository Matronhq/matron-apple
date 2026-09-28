import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class MissionsDashboardSnapshotTests: XCTestCase {
    /// Fixed so the relative ages in the snapshots never drift.
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }

    static let fullMission = Mission(
        id: "ms_1", num: 61, title: "Missions dashboard", originConvoID: "c1",
        createdAt: ago(86_400), updatedAt: ago(600), lastMilestoneAt: ago(1_800),
        needsYou: 4, conversationCount: 5,
        status: "Journal PR merged and **deployed**; bridge tool in review. Waiting on Dan for the card copy.",
        statusBy: .agent, statusUpdatedAt: ago(720))

    static let fullCard = DashboardMissionCard(
        mission: fullMission,
        latestStep: DashboardLatestStep(num: 88, kind: .progress, title: "Bridge mission_status tool wired",
                                        body: "Tests green; PR #301 open.", createdAt: ago(1_800)),
        needsYouCount: 4,
        needsYouItems: [
            DashboardNeedsYouItem(id: "it_1", num: 90, kind: .question, title: "Red or orange for the pill?"),
            DashboardNeedsYouItem(id: "it_2", num: 91, kind: .decision, title: "Ship behind a flag?"),
            DashboardNeedsYouItem(id: "it_3", num: 92, kind: .question, title: "Grid minimum 340 pt OK?"),
        ],
        sessions: [
            DashboardSession(id: "c1", title: "Journal status column", state: .running, lastActivity: ago(60),
                             summary: "Running the route tests for the 600-char limit",
                             tag: SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")),
            DashboardSession(id: "c2", title: "Bridge tool", state: .waiting, lastActivity: ago(900),
                             summary: "Waiting for review on PR #301"),
            DashboardSession(id: "c3", title: "Far box session", state: .done, summary: nil, boxName: "ci-3"),
        ],
        moreSessions: 2, anyRunning: true, lastActivity: ago(60))

    static let bareCard = DashboardMissionCard(
        mission: Mission(id: "ms_2", num: 62, title: "Rotate the relay keys", originConvoID: "c9",
                         createdAt: ago(3_600), updatedAt: ago(3_600), conversationCount: 1),
        sessions: [DashboardSession(id: "c9", title: "Key rotation", state: .waiting, lastActivity: ago(3_000))],
        lastActivity: ago(3_000))

    static let unassignedCard = DashboardMissionCard(
        mission: Mission(id: "ms_3", num: 63, title: "Audit the push relay", originConvoID: "c-coord",
                         createdAt: ago(7_200), updatedAt: ago(7_200)),
        attribution: "from Coordinator", lastActivity: ago(7_200))

    static let looseSession = DashboardSession(
        id: "c-loose", title: "Fix the flaky timeline test", state: .running, lastActivity: ago(120),
        summary: "Bisecting the gap test; two of five runs fail on CI only",
        tag: SessionTagInputs(boxLetter: "M", boxName: "mac", sessionShort: "qz"), needsYou: 1)

    // MARK: Pure

    func testRelativeAges() {
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(20), now: Self.now), "just now")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(720), now: Self.now), "12m ago")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(3 * 3_600), now: Self.now), "3h ago")
        XCTAssertEqual(MissionsDashboardFormat.relative(Self.ago(2 * 86_400), now: Self.now), "2d ago")
        XCTAssertTrue(MissionsDashboardFormat.relative(Self.ago(30 * 86_400), now: Self.now).hasPrefix("on "))
    }

    func testStatusBylineNamesTheWriter() {
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(720), by: .agent, now: Self.now),
                       "Updated 12m ago by an agent")
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(10), by: .user, now: Self.now),
                       "Updated just now by you")
        XCTAssertEqual(MissionsDashboardFormat.statusByline(updatedAt: Self.ago(720), by: nil, now: Self.now),
                       "Updated 12m ago")
        XCTAssertNil(MissionsDashboardFormat.statusByline(updatedAt: nil, by: .agent, now: Self.now))
    }

    func testAskedLabelAndMoreSessions() {
        XCTAssertEqual(MissionsDashboardFormat.askedLabel(askedAt: Self.ago(5), now: Self.now), "Asked just now")
        XCTAssertEqual(MissionsDashboardFormat.askedLabel(askedAt: Self.ago(300), now: Self.now), "Asked 5m ago")
        XCTAssertEqual(MissionsDashboardFormat.moreSessions(1), "+1 more session")
        XCTAssertEqual(MissionsDashboardFormat.moreSessions(3), "+3 more sessions")
    }

    /// Review Focus: `[label]: text` is a CommonMark link reference
    /// definition — block-level markdown renders it as nothing at all.
    func testStatusTextKeepsALabelColonLine() {
        let text = String(MissionsDashboardFormat.statusText("[blocked]: waiting on Dan").characters)
        XCTAssertTrue(text.contains("waiting on Dan"), "got \(text)")
        let bold = String(MissionsDashboardFormat.statusText("Bridge **deployed**").characters)
        XCTAssertEqual(bold, "Bridge deployed", "inline markdown is interpreted, not shown raw")
    }

    func testStateDotLabels() {
        XCTAssertEqual(DashboardStateDot.label(.running), "Running")
        XCTAssertEqual(DashboardStateDot.label(.waiting), "Waiting")
        XCTAssertEqual(DashboardStateDot.label(.done), "Done")
    }

    // MARK: Snapshots

    func testMissionCardFull() {
        assertVariants(of: MissionCardView(card: Self.fullCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-full")
    }

    func testMissionCardWithoutStatusOrMilestones() {
        assertVariants(of: MissionCardView(card: Self.bareCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-bare")
    }

    func testMissionCardUnassigned() {
        assertVariants(of: MissionCardView(card: Self.unassignedCard, now: Self.now, onAction: { _ in })
            .frame(width: 380).padding(), named: "dashboard-card-unassigned")
    }

    func testLooseSessionCard() {
        assertVariants(of: LooseSessionCardView(session: Self.looseSession, onOpen: {})
            .frame(width: 380).padding(), named: "dashboard-loose-card")
    }
}

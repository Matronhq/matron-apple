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
        status: "Journal PR merged and **deployed**; bridge tool in review. Waiting on Alice for the card copy.",
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
                             tag: SessionTagInputs(boxLetter: "B", boxName: "box-2", sessionShort: "bc")),
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
        let text = String(MissionsDashboardFormat.statusText("[blocked]: waiting on Alice").characters)
        XCTAssertTrue(text.contains("waiting on Alice"), "got \(text)")
        let bold = String(MissionsDashboardFormat.statusText("Bridge **deployed**").characters)
        XCTAssertEqual(bold, "Bridge deployed", "inline markdown is interpreted, not shown raw")
    }

    func testStateDotLabels() {
        XCTAssertEqual(DashboardStateDot.label(.running), "Running")
        XCTAssertEqual(DashboardStateDot.label(.waiting), "Waiting")
        XCTAssertEqual(DashboardStateDot.label(.done), "Done")
    }

    /// Fix round 1: `.accessibilityElement(children: .combine)` alone made a
    /// room session's tag read as the glyph run ("D↔M") letter by letter —
    /// mirrors `MissionDetailView`'s fix for the same bug
    /// (`SessionTagText.plainLabel`, not the visual run's letters).
    func testSessionRowAccessibilityLabelNamesRoomBoxesNotGlyphs() {
        let room = DashboardSession(
            id: "c-room", title: "Pairing on the row fix", state: .waiting, lastActivity: Self.ago(60),
            summary: "Reviewing the accessibility label change",
            tag: SessionTagInputs(boxLetter: "B", boxName: "box-2", sessionShort: "bc",
                                  roomBoxNames: ["box-2", "mac"], roomBoxShorts: ["D", "M"]))
        let label = DashboardSessionRow.accessibilityLabel(for: room, showsNeedsYou: false)
        XCTAssertEqual(label, "Pairing on the row fix, box-2, mac, bc, waiting, Reviewing the accessibility label change")
        XCTAssertTrue(label.contains("box-2"), "got \(label)")
        XCTAssertTrue(label.contains("mac"), "got \(label)")
        XCTAssertFalse(label.contains("↔"), "should speak box names, not the visual run's glyph separator: got \(label)")
    }

    /// Fix round 2: the explicit label above (rightly) stopped `.combine`
    /// from also merging in `NeedsYouBadge`'s own "N items need you" —
    /// which silently dropped the count from a loose-session card's
    /// VoiceOver announcement. The row's label must fold the same count
    /// back in, worded exactly like the badge, but only when the row is
    /// showing the badge in the first place (mission-card rows never do).
    func testSessionRowAccessibilityLabelIncludesNeedsYouCountWhenShown() {
        let session = Self.looseSession // needsYou: 1
        XCTAssertEqual(DashboardSessionRow.accessibilityLabel(for: session, showsNeedsYou: true),
                       "Fix the flaky timeline test, mac, qz, 1 item needs you, running, "
                       + "Bisecting the gap test; two of five runs fail on CI only")
        // Mission-card rows never show the badge — no count in the label.
        let noBadge = DashboardSessionRow.accessibilityLabel(for: session, showsNeedsYou: false)
        XCTAssertFalse(noBadge.contains("needs you"), "got \(noBadge)")

        let severalNeeded = DashboardSession(id: "c-many", title: "Many open questions", state: .waiting,
                                             needsYou: 3)
        XCTAssertEqual(DashboardSessionRow.accessibilityLabel(for: severalNeeded, showsNeedsYou: true),
                       "Many open questions, 3 items need you, waiting")

        // A session with nothing to report shows the badge but not a count.
        let none = DashboardSession(id: "c-none", title: "All clear", state: .done, needsYou: 0)
        let noneLabel = DashboardSessionRow.accessibilityLabel(for: none, showsNeedsYou: true)
        XCTAssertFalse(noneLabel.contains("needs you"), "got \(noneLabel)")
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

    // MARK: The page

    private static func pageModel(askedAt: Date? = nil) -> MissionsDashboardView.Model {
        MissionsDashboardView.Model(
            cards: [fullCard, bareCard, unassignedCard],
            looseSessions: [looseSession],
            closed: [Mission(id: "ms_0", num: 55, state: .closed, title: "Items tracker", closeSummary: "Shipped.",
                             closedBy: .agent, originConvoID: "c0", closedAt: ago(9 * 86_400))],
            isSupported: true, isRefreshing: false, askedAt: askedAt)
    }

    private func page(_ model: MissionsDashboardView.Model) -> MissionsDashboardView {
        MissionsDashboardView(model: model, now: Self.now, onAction: { _ in }, onRefresh: {}, onAsk: {})
    }

    func testModelEmptyState() {
        let empty = MissionsDashboardView.Model(cards: [], looseSessions: [], closed: [], isSupported: true, isRefreshing: false)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(MissionsDashboardView.Model(cards: [], looseSessions: [Self.looseSession], closed: [],
                                                   isSupported: true, isRefreshing: false).isEmpty)
        XCTAssertEqual(MissionsDashboardAskButton.title, "Ask the Coordinator to update")
    }

    func testDashboardEmpty() {
        let empty = MissionsDashboardView.Model(cards: [], looseSessions: [], closed: [], isSupported: true, isRefreshing: false)
        assertVariants(of: page(empty).frame(width: 390, height: 360), named: "dashboard-empty")
    }

    func testDashboardPhoneWidth() {
        assertVariants(of: page(Self.pageModel(askedAt: Self.ago(120))).frame(width: 390, height: 1_400),
                       named: "dashboard-phone")
    }

    func testDashboardIPadWidth() {
        assertVariants(of: page(Self.pageModel()).frame(width: 820, height: 1_000), named: "dashboard-ipad")
    }

    func testDashboardMacWidth() {
        assertVariants(of: page(Self.pageModel()).frame(width: 1_140, height: 820), named: "dashboard-wide")
    }
}

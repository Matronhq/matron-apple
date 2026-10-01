import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ConversationMissionsSnapshotTests: XCTestCase {
    static let d26 = Date(timeIntervalSince1970: 1_758_844_800) // 26 Sep 2025 UTC

    static var missions: ConversationMissions {
        let current = Mission(id: "ms_4791", num: 4791, title: "Promo branch: /proto design at the base URLs",
                              originConvoID: "c1", projectID: "pj_1")
        let also = Mission(id: "ms_4907", num: 4907, title: "Launch day: Wed 7 Oct 07:00", originConvoID: "c9",
                           projectID: "pj_1")
        let earlier = Mission(id: "ms_4083", num: 4083, title: "Combined promo branch: gather and report",
                              originConvoID: "c1")
        return ConversationMissions(links: [
            ConversationMissionLink(mission: current, isCurrent: true, joinedAt: d26),
            ConversationMissionLink(mission: also, joinedAt: d26.addingTimeInterval(4 * 86_400)),
            ConversationMissionLink(mission: earlier, isActive: false, joinedAt: d26.addingTimeInterval(2 * 86_400),
                                    endedAt: d26.addingTimeInterval(3 * 86_400)),
        ], snapshotCount: 3)
    }

    func testChipText() {
        XCTAssertEqual(MissionChipLabel.text(Self.missions), "#4791 Promo branch: /proto design at the base URLs +2")
        XCTAssertNil(MissionChipLabel.text(ConversationMissions()))
        let one = ConversationMissions(links: [Self.missions.links[0]], snapshotCount: nil)
        XCTAssertEqual(MissionChipLabel.text(one), "#4791 Promo branch: /proto design at the base URLs")
    }

    func testChip() {
        assertVariants(of: MissionChipLabel(missions: Self.missions).frame(width: 320).padding(), named: "mission-chip")
    }

    func testMissionsList() {
        let list = ConversationMissionsList(missions: Self.missions, projectTitles: ["pj_1": "Promo launch"],
                                            onOpenMission: { _ in }, onOpenProject: { _ in })
            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
        assertVariants(of: list.frame(width: 390, height: 620), named: "conversation-missions-list")
    }

    /// Bugbot 280-1: the project chip is a Button, so the row must not be
    /// one too — a button in a button's label never gets the tap. Pins the
    /// row's shape: no Button anywhere in its body's type (the chip's own
    /// Button sits behind `ProjectChip`'s opaque body), the chip present,
    /// and the row's open-mission tap on a gesture.
    func testTheRowIsNotAButtonSoTheChipGetsItsOwnTap() {
        let row = ConversationMissionRow(link: Self.missions.links[0], projectTitles: ["pj_1": "Promo launch"],
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         onOpenMission: { _ in }, onOpenProject: { _ in })
        let shape = String(reflecting: type(of: row.body))
        XCTAssertFalse(shape.contains("Button<"), shape)
        XCTAssertTrue(shape.contains("ProjectChip"), shape)
        XCTAssertTrue(shape.contains("TapGesture"), shape)
    }

    // MARK: iOS header subtitle (the workdir line stays)

    static let longWorkdir = "pat · ~/Dev/yearbook-app/worktrees/promo-integration-owner-2026-10-07"

    private func subtitle(_ context: String?, _ missions: ConversationMissions, width: CGFloat) -> some View {
        ChatHeaderSubtitle(context: context, missions: missions, onTapChip: {})
            .frame(width: width).padding(4)
    }

    func testSubtitleFlags() {
        XCTAssertEqual(ChatHeaderSubtitle.contextMinWidth, 96)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "pat · ~/x", missions: Self.missions), .contextAndChip)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: Self.missions), .chipOnly)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "pat · ~/x", missions: ConversationMissions()), .contextOnly)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: ConversationMissions()), .none)
    }

    /// Room for both: one line, the long workdir middle-truncated, the chip whole.
    func testSubtitleLongWorkdirSharesTheLine() {
        let short = ConversationMissions(links: [ConversationMissionLink(
            mission: Mission(id: "ms_61", num: 61, title: "Launch", originConvoID: "c1"), isCurrent: true)])
        assertVariants(of: subtitle(Self.longWorkdir, short, width: 300), named: "chat-subtitle-long-workdir-one-line")
    }

    /// No room for the chip beside 96 pt of workdir: a compact third line.
    func testSubtitleLongWorkdirAndLongChipTakeTwoLines() {
        assertVariants(of: subtitle(Self.longWorkdir, Self.missions, width: 300), named: "chat-subtitle-long-workdir-two-lines")
    }

    func testSubtitleWithoutMissionsIsTodaysLine() {
        assertVariants(of: subtitle(Self.longWorkdir, ConversationMissions(), width: 300), named: "chat-subtitle-no-missions")
    }

    func testLooseSection() {
        let sessions = [DashboardSession(id: "c-loose", title: "Fix the flaky timeline test", state: .running,
                                         summary: "Bisecting the gap test", needsYou: 1)]
        let list = List { LooseSessionsSection(sessions: sessions, isExpanded: .constant(true), onOpen: { _ in }) }
        assertVariants(of: list.frame(width: 390, height: 240), named: "loose-sessions-section")
    }
}

import XCTest
import SwiftUI
import MatronModels
@testable import MatronDesignSystem

final class ConversationMissionsSnapshotTests: XCTestCase {
    static let d26 = Date(timeIntervalSince1970: 1_758_844_800) // 26 Sep 2025 UTC

    static var missions: ConversationMissions {
        let current = Mission(id: "ms_2171", num: 2171, title: "Search on the docs site: the index and the results page",
                              originConvoID: "c1", projectID: "pj_1")
        let also = Mission(id: "ms_2173", num: 2173, title: "Launch day: rehearsal, then the switch-over", originConvoID: "c9",
                           projectID: "pj_1")
        let earlier = Mission(id: "ms_2172", num: 2172, title: "Move the old pages across: list and report",
                              originConvoID: "c1")
        return ConversationMissions(links: [
            ConversationMissionLink(mission: current, isCurrent: true, joinedAt: d26),
            ConversationMissionLink(mission: also, joinedAt: d26.addingTimeInterval(4 * 86_400)),
            ConversationMissionLink(mission: earlier, isActive: false, joinedAt: d26.addingTimeInterval(2 * 86_400),
                                    endedAt: d26.addingTimeInterval(3 * 86_400)),
        ], snapshotCount: 3)
    }

    func testChipText() {
        XCTAssertEqual(MissionChipLabel.text(Self.missions), "#2171 Search on the docs site: the index and the results page +2")
        XCTAssertNil(MissionChipLabel.text(ConversationMissions()))
        let one = ConversationMissions(links: [Self.missions.links[0]], snapshotCount: nil)
        XCTAssertEqual(MissionChipLabel.text(one), "#2171 Search on the docs site: the index and the results page")
    }

    /// A mission-named conversation's title already says the mission
    /// (journal PR 136), so the chip drops the name — matched on `name` or
    /// `title`, past the `[xx]` short and marker, and past the journal's
    /// cut to 40 characters.
    func testChipDropsTheNameTheTitleAlreadySays() {
        let docsSite = Self.missions.links[0].mission
        func repeats(_ title: String?, _ mission: Mission? = nil) -> Bool {
            MissionChipLabel.repeatsTitle(mission ?? docsSite, conversationTitle: title)
        }
        XCTAssertTrue(repeats("Search on the docs site: the index and the results page"))
        XCTAssertTrue(repeats("[b5] Search on the docs site: the index and the results page"), "the raw title, short and all")
        XCTAssertTrue(repeats("🐣 [b5] Search on the docs site: the index and the results page"), "a spawned session's marker")
        XCTAssertTrue(repeats("Search on the docs site: the index and…"), "the journal's 40-character cut")
        XCTAssertTrue(repeats("Search on the docs site:  the index and the results page "), "whitespace collapsed")
        XCTAssertFalse(repeats(nil))
        XCTAssertFalse(repeats(""))
        XCTAssertFalse(repeats("…"))
        XCTAssertFalse(repeats("Docs search"), "a different, shorter title")
        XCTAssertFalse(repeats("Launch day: rehearsal…"), "a cut of some other title")
        let named = Mission(id: "ms_9", num: 9, title: "A long mission title nobody reads", originConvoID: "c1",
                            name: "Docs")
        XCTAssertTrue(repeats("[b5] Docs", named), "matched on the mission's name")
        XCTAssertFalse(repeats("[b5] Docs site launch", named))

        XCTAssertEqual(MissionChipLabel.text(Self.missions, conversationTitle: "[b5] Search on the docs site: the index and…"),
                       "#2171 +2")
        XCTAssertEqual(MissionChipLabel.text(Self.missions, conversationTitle: "Something else"),
                       "#2171 Search on the docs site: the index and the results page +2")
    }

    func testChip() {
        assertVariants(of: MissionChipLabel(missions: Self.missions).frame(width: 320).padding(), named: "mission-chip")
    }

    func testMissionsList() {
        let list = ConversationMissionsList(missions: Self.missions, projectTitles: ["pj_1": "Docs site launch"],
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
        let row = ConversationMissionRow(link: Self.missions.links[0], projectTitles: ["pj_1": "Docs site launch"],
                                         timeZone: TimeZone(identifier: "UTC")!,
                                         onOpenMission: { _ in }, onOpenProject: { _ in })
        let shape = String(reflecting: type(of: row.body))
        XCTAssertFalse(shape.contains("Button<"), shape)
        XCTAssertTrue(shape.contains("ProjectChip"), shape)
        XCTAssertTrue(shape.contains("TapGesture"), shape)
    }

    // MARK: iOS header subtitle (the workdir line stays)

    static let longWorkdir = "box-a · ~/dev/acme-app/worktrees/docs-search-results-page-owner"

    private func subtitle(_ context: String?, _ missions: ConversationMissions, width: CGFloat) -> some View {
        ChatHeaderSubtitle(context: context, missions: missions, onTapChip: {})
            .frame(width: width).padding(4)
    }

    func testSubtitleFlags() {
        XCTAssertEqual(ChatHeaderSubtitle.contextMinWidth, 96)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "box-a · ~/x", missions: Self.missions), .contextAndChip)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: nil, missions: Self.missions), .chipOnly)
        XCTAssertEqual(ChatHeaderSubtitle.layout(context: "box-a · ~/x", missions: ConversationMissions()), .contextOnly)
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
}

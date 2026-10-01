import XCTest
import MatronModels
@testable import MatronJournal

final class ProjectModelTests: XCTestCase {
    static let projectJSON: [String: Any] = [
        "id": "pj_1", "num": 4000, "state": "open", "title": "Promo launch",
        "body": "New promo site, blog and leavers' page.",
        "status": "Launch Wed 7 Oct, 07:00.", "status_by": "agent", "status_updated_at": 1_700_000_006_000,
        "close_summary": NSNull(), "closed_at": NSNull(), "merged_into": NSNull(),
        "origin_convo_id": "c-coord", "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_006_000,
        "missions": ["running": 2, "waiting": 2, "idle": 0, "quiet": 1, "closed": 3],
        "needs_you": 6, "open_items": 37, "last_activity_at": 1_700_000_005_000,
    ]

    func testProjectDecodesAListRow() throws {
        let p = try XCTUnwrap(Project(json: Self.projectJSON))
        XCTAssertEqual(p.id, "pj_1"); XCTAssertEqual(p.num, 4000); XCTAssertEqual(p.state, .open)
        XCTAssertEqual(p.title, "Promo launch")
        XCTAssertEqual(p.status, "Launch Wed 7 Oct, 07:00.")
        XCTAssertEqual(p.statusBy, .agent)
        XCTAssertEqual(p.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_006))
        XCTAssertEqual(p.missions, ProjectMissionCounts(running: 2, waiting: 2, idle: 0, quiet: 1, closed: 3))
        XCTAssertEqual(p.missions.open, 5)
        XCTAssertEqual(p.needsYou, 6); XCTAssertEqual(p.openItems, 37)
        XCTAssertEqual(p.lastActivityAt, Date(timeIntervalSince1970: 1_700_000_005))
        XCTAssertEqual(p.label, "#4000 Promo launch")
    }

    /// An older or partial row without the rollup keys decodes with zero
    /// counts; a sieved status is null; a merged one names its target.
    func testProjectToleratesMissingCountsAndReadsMergedInto() throws {
        var json = Self.projectJSON
        json.removeValue(forKey: "missions"); json.removeValue(forKey: "needs_you")
        json["status"] = NSNull(); json["state"] = "closed"; json["merged_into"] = "pj_2"
        let p = try XCTUnwrap(Project(json: json))
        XCTAssertEqual(p.missions, ProjectMissionCounts())
        XCTAssertEqual(p.needsYou, 0)
        XCTAssertNil(p.status)
        XCTAssertEqual(p.state, .closed)
        XCTAssertEqual(p.mergedInto, "pj_2")
    }

    func testProjectWithoutItsIdentityIsDropped() {
        XCTAssertNil(Project(json: ["id": "pj_x", "title": "No number"]))
    }

    func testConversationMissionLinkDecodesAFlatRow() throws {
        var row = MissionModelTests.missionJSON
        row["current"] = true; row["active"] = true; row["joined_at"] = 1_700_000_001_000; row["how"] = "origin"
        let link = try XCTUnwrap(ConversationMissionLink(json: row))
        XCTAssertEqual(link.mission.id, "ms_a1")
        XCTAssertTrue(link.isCurrent); XCTAssertTrue(link.isActive); XCTAssertFalse(link.isEarlier)
        XCTAssertEqual(link.joinedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(link.how, "origin")
    }

    /// No `active` key: an `ended_at` decides it. A closed mission's link is
    /// history even while it is still active (spec §3, "Closing a mission").
    func testLinkActivityFallsBackToEndedAtAndClosedMissionsAreEarlier() throws {
        var ended = MissionModelTests.missionJSON
        ended["ended_at"] = 1_700_000_009_000
        XCTAssertFalse(try XCTUnwrap(ConversationMissionLink(json: ended)).isActive)
        var closed = MissionModelTests.missionJSON
        closed["state"] = "closed"
        let link = try XCTUnwrap(ConversationMissionLink(json: closed))
        XCTAssertTrue(link.isActive)
        XCTAssertTrue(link.isEarlier)
    }

    private func link(_ id: String, num: Int, current: Bool = false, joined: TimeInterval? = nil,
                      ended: TimeInterval? = nil, closed: Bool = false) -> ConversationMissionLink {
        ConversationMissionLink(
            mission: Mission(id: id, num: num, state: closed ? .closed : .open, title: "M\(num)", originConvoID: "c1"),
            isCurrent: current, isActive: ended == nil,
            joinedAt: joined.map { Date(timeIntervalSince1970: $0) },
            endedAt: ended.map { Date(timeIntervalSince1970: $0) })
    }

    func testSectionsSplitCurrentAlsoOnAndEarlier() {
        let sections = ConversationMissionSections([
            link("ms_old", num: 1, joined: 1, ended: 5),
            link("ms_also", num: 2, joined: 10),
            link("ms_cur", num: 3, current: true, joined: 20),
            link("ms_newer_also", num: 4, joined: 30),
            link("ms_done", num: 5, joined: 2, closed: true),
        ])
        XCTAssertEqual(sections.current?.id, "ms_cur")
        XCTAssertEqual(sections.alsoOn.map(\.id), ["ms_newer_also", "ms_also"], "newest joined first")
        XCTAssertEqual(Set(sections.earlier.map(\.id)), ["ms_old", "ms_done"])
        XCTAssertEqual(sections.headline?.id, "ms_cur")
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 4)
    }

    /// Before `GET /conversations/:id/missions` lands, only the snapshot's
    /// `mission_count` knows the others exist.
    func testOthersCountTrustsALargerSnapshotCount() {
        let sections = ConversationMissionSections([link("ms_cur", num: 3, current: true, joined: 20)])
        XCTAssertEqual(sections.othersCount(snapshotCount: 3), 2)
        XCTAssertEqual(sections.othersCount(snapshotCount: nil), 0)
        XCTAssertEqual(ConversationMissionSections([]).othersCount(snapshotCount: 2), 0,
                       "no headline, no chip, no count")
    }

    /// No current link (the conversation left its last mission): the chip
    /// names the newest active one, else the newest earlier one.
    func testHeadlineFallsBackWhenNothingIsCurrent() {
        let sections = ConversationMissionSections([link("ms_old", num: 1, joined: 1, ended: 5)])
        XCTAssertNil(sections.current)
        XCTAssertEqual(sections.headline?.id, "ms_old")
    }
}

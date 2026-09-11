import XCTest
import MatronModels
@testable import MatronJournal

final class MissionModelTests: XCTestCase {
    /// Exactly the mission row `POST /missions` returns in the journal's
    /// conformance fixture (15_missions_roundtrip.json), plus the counts
    /// `GET /missions` adds. `idem_key` is never returned by the journal.
    static let missionJSON: [String: Any] = [
        "id": "ms_a1", "user_id": 1, "num": 61, "state": "open",
        "title": "Missions & milestones", "body": "Ship it",
        "close_summary": NSNull(), "closed_by": NSNull(), "closed_over_open_items": 0,
        "origin_convo_id": "c1", "origin_device_id": 3, "created_by": "agent",
        "created_at": 1_700_000_000_000, "updated_at": 1_700_000_005_000,
        "last_milestone_at": 1_700_000_004_000, "closed_at": NSNull(),
        "open_items": 2, "needs_you": 1, "conversations": 3, "milestones": 4,
        "last_milestone": ["num": 63, "title": "Wired the migration", "kind": "user_input", "created_at": 1_700_000_004_000],
    ]

    static let milestoneJSON: [String: Any] = [
        "id": "ml_b2", "mission_id": "ms_a1", "user_id": 1, "num": 63, "kind": "user_input",
        "title": "Dan asked for missions", "body": "the brief", "convo_id": "c1", "seq": 4210,
        "device_id": 3, "created_by": "agent", "created_at": 1_700_000_004_000,
    ]

    func testMissionDecodesIncludingCountsAndLastMilestone() throws {
        let m = try XCTUnwrap(Mission(json: Self.missionJSON))
        XCTAssertEqual(m.id, "ms_a1"); XCTAssertEqual(m.num, 61); XCTAssertEqual(m.state, .open)
        XCTAssertEqual(m.title, "Missions & milestones"); XCTAssertEqual(m.body, "Ship it")
        XCTAssertNil(m.closeSummary); XCTAssertNil(m.closedBy); XCTAssertEqual(m.closedOverOpenItems, 0)
        XCTAssertEqual(m.originConvoID, "c1"); XCTAssertEqual(m.createdBy, .agent)
        XCTAssertEqual(m.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(m.lastMilestoneAt, Date(timeIntervalSince1970: 1_700_000_004))
        XCTAssertNil(m.closedAt)
        XCTAssertEqual(m.openItems, 2); XCTAssertEqual(m.needsYou, 1)
        XCTAssertEqual(m.conversationCount, 3); XCTAssertEqual(m.milestoneCount, 4)
        XCTAssertEqual(m.lastMilestone?.num, 63)
        XCTAssertEqual(m.lastMilestone?.kind, .userInput)
        XCTAssertEqual(m.lastMilestone?.title, "Wired the migration")
    }

    /// A mission row with none of the `GET /missions` counts (the shape
    /// `POST /missions/:id/close` and `PATCH` return) must still decode —
    /// the counts default to zero rather than failing the whole row.
    func testMissionDecodesWithoutCounts() throws {
        var bare = Self.missionJSON
        for key in ["open_items", "needs_you", "conversations", "milestones", "last_milestone"] { bare.removeValue(forKey: key) }
        let m = try XCTUnwrap(Mission(json: bare))
        XCTAssertEqual(m.openItems, 0); XCTAssertEqual(m.needsYou, 0)
        XCTAssertEqual(m.conversationCount, 0); XCTAssertEqual(m.milestoneCount, 0)
        XCTAssertNil(m.lastMilestone)
    }

    func testMissionRejectsUnknownStateAndMissingKeys() {
        var bad = Self.missionJSON; bad["state"] = "paused"
        XCTAssertNil(Mission(json: bad))
        bad = Self.missionJSON; bad.removeValue(forKey: "num")
        XCTAssertNil(Mission(json: bad))
        bad = Self.missionJSON; bad.removeValue(forKey: "origin_convo_id")
        XCTAssertNil(Mission(json: bad))
    }

    func testClosedMissionCarriesSummaryAndOverride() throws {
        var closed = Self.missionJSON
        closed["state"] = "closed"; closed["close_summary"] = "Done."; closed["closed_by"] = "user"
        closed["closed_over_open_items"] = 2; closed["closed_at"] = 1_700_000_009_000
        let m = try XCTUnwrap(Mission(json: closed))
        XCTAssertEqual(m.state, .closed); XCTAssertEqual(m.closeSummary, "Done.")
        XCTAssertEqual(m.closedBy, .user); XCTAssertEqual(m.closedOverOpenItems, 2)
        XCTAssertEqual(m.closedAt, Date(timeIntervalSince1970: 1_700_000_009))
    }

    func testMilestoneDecodesAndKeepsItsAnchorSeq() throws {
        let ms = try XCTUnwrap(Milestone(json: Self.milestoneJSON))
        XCTAssertEqual(ms.id, "ml_b2"); XCTAssertEqual(ms.missionID, "ms_a1"); XCTAssertEqual(ms.num, 63)
        XCTAssertEqual(ms.kind, .userInput); XCTAssertEqual(ms.title, "Dan asked for missions")
        XCTAssertEqual(ms.body, "the brief"); XCTAssertEqual(ms.convoID, "c1")
        XCTAssertEqual(ms.seq, 4210); XCTAssertEqual(ms.deviceID, 3); XCTAssertEqual(ms.createdBy, .agent)
        XCTAssertEqual(ms.createdAt, Date(timeIntervalSince1970: 1_700_000_004))
    }

    func testMilestoneRejectsUnknownKind() {
        var bad = Self.milestoneJSON; bad["kind"] = "vibes"
        XCTAssertNil(Milestone(json: bad))
        bad = Self.milestoneJSON; bad.removeValue(forKey: "seq")
        XCTAssertNil(Milestone(json: bad), "a milestone with no anchor is unusable — reject it")
    }

    func testMissionConversationDecodes() throws {
        let c = try XCTUnwrap(MissionConversation(json: ["id": "c1", "title": "Session", "box": "dev-2", "state": "running"]))
        XCTAssertEqual(c.id, "c1"); XCTAssertEqual(c.title, "Session")
        XCTAssertEqual(c.box, "dev-2"); XCTAssertEqual(c.state, "running")
        let noBox = try XCTUnwrap(MissionConversation(json: ["id": "c2", "title": "Other", "box": NSNull(), "state": "idle"]))
        XCTAssertNil(noBox.box)
    }

    /// `items.mission_id` / `mission_num` ride the ordinary item row (the
    /// journal's DECORATE adds them). Both are optional: an item filed in a
    /// conversation with no mission has neither.
    func testTrackerItemCarriesMissionIdentity() throws {
        var json = ItemsAPITests.itemJSON
        json["mission_id"] = "ms_a1"; json["mission_num"] = 61
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertEqual(item.missionID, "ms_a1"); XCTAssertEqual(item.missionNum, 61)
        let unassigned = try XCTUnwrap(TrackerItem(json: ItemsAPITests.itemJSON))
        XCTAssertNil(unassigned.missionID); XCTAssertNil(unassigned.missionNum)
    }
}

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
        "title": "Alice asked for missions", "body": "the brief", "convo_id": "c1", "seq": 4210,
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
        XCTAssertEqual(ms.kind, .userInput); XCTAssertEqual(ms.title, "Alice asked for missions")
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
        let c = try XCTUnwrap(MissionConversation(json: ["id": "c1", "title": "Session", "box": "box-2", "state": "running"]))
        XCTAssertEqual(c.id, "c1"); XCTAssertEqual(c.title, "Session")
        XCTAssertEqual(c.box, "box-2"); XCTAssertEqual(c.state, "running")
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

    /// Spec 2026-09-28 §1: every mission object carries the status fields.
    func testMissionDecodesStatusFields() throws {
        var json = Self.missionJSON
        json["status"] = "Journal half merged; bridge next."
        json["status_by"] = "agent"
        json["status_convo_id"] = "c2"
        json["status_updated_at"] = 1_700_000_006_000
        let m = try XCTUnwrap(Mission(json: json))
        XCTAssertEqual(m.status, "Journal half merged; bridge next.")
        XCTAssertEqual(m.statusBy, .agent)
        XCTAssertEqual(m.statusUpdatedAt, Date(timeIntervalSince1970: 1_700_000_006))
    }

    /// An old journal sends none of them; a sieved one sends nulls; a
    /// future one might send a `status_by` this build doesn't know. None of
    /// those may drop the row.
    func testMissionToleratesAbsentOrMalformedStatus() throws {
        let bare = try XCTUnwrap(Mission(json: Self.missionJSON))
        XCTAssertNil(bare.status); XCTAssertNil(bare.statusBy); XCTAssertNil(bare.statusUpdatedAt)

        var odd = Self.missionJSON
        odd["status"] = NSNull(); odd["status_by"] = "robot"; odd["status_updated_at"] = "yesterday"
        let m = try XCTUnwrap(Mission(json: odd), "a malformed status must not drop the row")
        XCTAssertNil(m.status); XCTAssertNil(m.statusBy); XCTAssertNil(m.statusUpdatedAt)

        var empty = Self.missionJSON
        empty["status"] = ""
        XCTAssertNil(try XCTUnwrap(Mission(json: empty)).status, "an empty status reads as unset")
    }

    func testMissionDecodesProjectAndActivity() throws {
        var json = Self.missionJSON
        json["project_id"] = "pj_1"; json["project_num"] = 4000; json["activity"] = "waiting"
        json["last_activity_at"] = 1_700_000_007_000
        let m = try XCTUnwrap(Mission(json: json))
        XCTAssertEqual(m.projectID, "pj_1"); XCTAssertEqual(m.projectNum, 4000); XCTAssertEqual(m.activity, .waiting)
        XCTAssertEqual(m.lastActivityAt, Date(timeIntervalSince1970: 1_700_000_007))

        var odd = Self.missionJSON
        odd["project_id"] = NSNull(); odd["activity"] = "asleep"
        let o = try XCTUnwrap(Mission(json: odd), "an unknown activity must not drop the row")
        XCTAssertNil(o.projectID); XCTAssertNil(o.projectNum); XCTAssertNil(o.activity)
        XCTAssertNil(o.lastActivityAt, "an older journal sends none of it")
    }

    func testMissionConversationDecodesLinkFields() throws {
        let c = try XCTUnwrap(MissionConversation(json: [
            "id": "c1:sub:a", "title": "child", "box": "slate", "state": "done",
            "current": false, "joined_at": 1_700_000_001_000, "ended_at": 1_700_000_002_000,
            "how": "inherited", "parent_convo_id": "c1", "subchat_count": 0,
        ]))
        XCTAssertFalse(c.isCurrent); XCTAssertFalse(c.isActive)
        XCTAssertEqual(c.joinedAt, Date(timeIntervalSince1970: 1_700_000_001))
        XCTAssertEqual(c.endedAt, Date(timeIntervalSince1970: 1_700_000_002))
        XCTAssertEqual(c.how, "inherited"); XCTAssertEqual(c.parentConvoID, "c1")

        let old = try XCTUnwrap(MissionConversation(json: ["id": "c2", "title": "T", "state": "running"]))
        XCTAssertTrue(old.isActive, "an old journal's row has no ended_at: active")
        XCTAssertFalse(old.isCurrent); XCTAssertEqual(old.subchatCount, 0)
        XCTAssertEqual(old.otherMissions, [], "no other_missions on an old journal: empty")
    }

    /// `other_missions` (journal plan addendum): decoded in journal order;
    /// an entry without its identity is dropped, the rest kept.
    func testMissionConversationDecodesOtherMissions() throws {
        let c = try XCTUnwrap(MissionConversation(json: [
            "id": "c1", "title": "promo/integration owner", "state": "running",
            "other_missions": [
                ["id": "ms_4791", "num": 4791, "title": "Promo branch", "current": true, "active": true,
                 "joined_at": 1_700_000_001_000],
                ["id": "ms_4083", "num": 4083, "title": "Combined promo branch", "current": false, "active": false,
                 "joined_at": 1_700_000_000_000, "ended_at": 1_700_000_002_000],
                ["title": "no id"],
            ],
        ]))
        XCTAssertEqual(c.otherMissions.map(\.num), [4791, 4083])
        XCTAssertTrue(c.otherMissions[0].isCurrent); XCTAssertTrue(c.otherMissions[0].isActive)
        XCTAssertFalse(c.otherMissions[1].isActive)
        XCTAssertEqual(c.otherMissions[1].endedAt, Date(timeIntervalSince1970: 1_700_000_002))
        let folded = try XCTUnwrap(MissionConversation(json: ["id": "c1:sub:a", "other_missions": NSNull()]))
        XCTAssertEqual(folded.otherMissions, [], "null reads as empty, never a dropped row")
    }

    /// Mission-named conversations (journal PR 136): a mission's optional
    /// `name`, and a conversation row's `auto_title` — the bridge's own
    /// title, drawn as a second line when it differs.
    func testMissionDecodesOptionalName() throws {
        var json = Self.missionJSON
        XCTAssertNil(try XCTUnwrap(Mission(json: json)).name, "an older journal sends no name")
        json["name"] = NSNull()
        XCTAssertNil(try XCTUnwrap(Mission(json: json)).name)
        json["name"] = ""
        XCTAssertNil(try XCTUnwrap(Mission(json: json)).name, "empty reads as none")
        json["name"] = "Promo launch"
        XCTAssertEqual(try XCTUnwrap(Mission(json: json)).name, "Promo launch")
    }

    func testMissionConversationDecodesAutoTitleAndSplitsTheShort() throws {
        let named = try XCTUnwrap(MissionConversation(json: [
            "id": "c1", "title": "[b5] Promo launch", "auto_title": "[b5] Fix the promo base URLs", "state": "running",
        ]))
        XCTAssertEqual(named.autoTitle, "[b5] Fix the promo base URLs")
        XCTAssertEqual(named.sessionShort, "b5")
        XCTAssertEqual(named.displayTitle, "Promo launch")
        XCTAssertEqual(named.displayAutoTitle, "Fix the promo base URLs")

        let same = try XCTUnwrap(MissionConversation(json: [
            "id": "c2", "title": "🐣 [ab] Topic", "auto_title": "🐣 [ab] Topic", "state": "idle",
        ]))
        XCTAssertEqual(same.displayTitle, "🐣 Topic")
        XCTAssertNil(same.displayAutoTitle, "no second line repeating the title")

        let old = try XCTUnwrap(MissionConversation(json: ["id": "c3", "title": "", "state": "idle"]))
        XCTAssertNil(old.autoTitle); XCTAssertNil(old.displayAutoTitle); XCTAssertNil(old.sessionShort)
        XCTAssertEqual(old.displayTitle, "c3", "an untitled row falls back to its id")
    }

    /// A mission page row leads with the conversation's
    /// topic — its title is the mission's name, which the page already
    /// says — and falls back to the title when there is no topic.
    func testMissionRowTitleIsTheTopicElseTheTitle() throws {
        let named = try XCTUnwrap(MissionConversation(json: [
            "id": "c1", "title": "[b5] Promo launch", "auto_title": "[b5] Fix the promo base URLs", "state": "running",
        ]))
        XCTAssertEqual(named.missionRowTitle, "Fix the promo base URLs")

        let same = try XCTUnwrap(MissionConversation(json: [
            "id": "c2", "title": "🐣 [ab] Topic", "auto_title": "🐣 [ab] Topic", "state": "idle",
        ]))
        XCTAssertEqual(same.missionRowTitle, "🐣 Topic")

        let noTopic = try XCTUnwrap(MissionConversation(json: ["id": "c3", "title": "[cd] Older chat", "state": "idle"]))
        XCTAssertEqual(noTopic.missionRowTitle, "Older chat")

        let blankTopic = try XCTUnwrap(MissionConversation(json: [
            "id": "c4", "title": "[ef] Promo launch", "auto_title": "", "state": "idle",
        ]))
        XCTAssertEqual(blankTopic.missionRowTitle, "Promo launch", "an empty topic is no topic")

        let untitled = try XCTUnwrap(MissionConversation(json: ["id": "c5", "title": "", "state": "idle"]))
        XCTAssertEqual(untitled.missionRowTitle, "c5")
    }
}

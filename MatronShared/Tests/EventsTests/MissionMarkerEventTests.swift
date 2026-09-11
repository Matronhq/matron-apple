import XCTest
import MatronModels
@testable import MatronEvents

final class MissionMarkerEventTests: XCTestCase {
    /// The milestone payload exactly as the journal's conformance fixture
    /// (15_missions_roundtrip.json) shows it on GET /convo/:id/messages.
    static let milestonePayload: [String: Any] = [
        "milestone_id": "ml_b2", "num": 63, "kind": "user_input",
        "title": "Dan asked for missions", "body": "the brief",
        "mission_id": "ms_a1", "mission_num": 61, "mission_title": "Missions & milestones",
        "by": "agent",
    ]

    static let missionPayload: [String: Any] = [
        "mission_id": "ms_a1", "num": 61, "title": "Missions & milestones",
        "action": "created", "by": "agent",
    ]

    func testMilestoneMarkerParses() throws {
        let m = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: Self.milestonePayload))
        XCTAssertEqual(m.milestoneID, "ml_b2"); XCTAssertEqual(m.num, 63)
        XCTAssertEqual(m.kind, .userInput); XCTAssertEqual(m.title, "Dan asked for missions")
        XCTAssertEqual(m.body, "the brief"); XCTAssertEqual(m.missionID, "ms_a1")
        XCTAssertEqual(m.missionNum, 61); XCTAssertEqual(m.missionTitle, "Missions & milestones")
        XCTAssertEqual(m.by, .agent); XCTAssertEqual(m.missionLabel, "Missions & milestones")
    }

    /// Protocol, "Markers written across the boundary carry numbers only":
    /// a marker written into a public conversation for a private-origin
    /// mission omits `mission_title`. It must still parse, and it must
    /// render as `#61` — never as an empty string.
    func testMilestoneMarkerWithoutMissionTitleFallsBackToTheNumber() throws {
        var sieved = Self.milestonePayload
        sieved.removeValue(forKey: "mission_title")
        let m = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: sieved))
        XCTAssertNil(m.missionTitle)
        XCTAssertEqual(m.missionLabel, "#61")
        XCTAssertEqual(m.missionNum, 61, "the number always crosses the boundary")
        XCTAssertEqual(m.title, "Dan asked for missions", "the milestone's OWN title is that conversation's content and stays")
    }

    func testMilestoneMarkerRejectsMissingIdentityAndUnknownKind() {
        var bad = Self.milestonePayload; bad["kind"] = "vibes"
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad))
        bad = Self.milestonePayload; bad.removeValue(forKey: "mission_id")
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad))
        bad = Self.milestonePayload; bad.removeValue(forKey: "mission_num")
        XCTAssertNil(MilestoneMarkerEvent.parse(payload: bad), "with no number there is nothing to fall back to")
    }

    func testMissionMarkerParsesEveryAction() throws {
        for action in ["created", "joined", "updated", "closed"] {
            var payload = Self.missionPayload; payload["action"] = action
            let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: payload), action)
            XCTAssertEqual(m.action.rawValue, action)
            XCTAssertEqual(m.missionID, "ms_a1"); XCTAssertEqual(m.num, 61)
            XCTAssertEqual(m.missionLabel, "Missions & milestones")
            XCTAssertTrue(m.openItemNums.isEmpty)
        }
        var unknown = Self.missionPayload; unknown["action"] = "vaporised"
        XCTAssertNil(MissionMarkerEvent.parse(payload: unknown))
    }

    func testMissionMarkerWithoutTitleFallsBackToTheNumber() throws {
        var sieved = Self.missionPayload
        sieved["action"] = "joined"; sieved.removeValue(forKey: "title")
        let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: sieved))
        XCTAssertNil(m.title)
        XCTAssertEqual(m.missionLabel, "#61")
    }

    /// A user-forced close records which item numbers were still open.
    func testMissionCloseMarkerCarriesOpenItemNumbers() throws {
        var payload = Self.missionPayload
        payload["action"] = "closed"; payload["by"] = "user"; payload["open_item_nums"] = [64, 70]
        let m = try XCTUnwrap(MissionMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.action, .closed); XCTAssertEqual(m.by, .user)
        XCTAssertEqual(m.openItemNums, [64, 70])
    }

    /// One stream carries both kinds — `MissionsSync` needs the mission id
    /// out of either without switching at every call site.
    func testMissionMarkerUnionExposesTheMissionID() throws {
        let milestone = try XCTUnwrap(MilestoneMarkerEvent.parse(payload: Self.milestonePayload))
        let mission = try XCTUnwrap(MissionMarkerEvent.parse(payload: Self.missionPayload))
        XCTAssertEqual(MissionMarker.milestone(milestone).missionID, "ms_a1")
        XCTAssertEqual(MissionMarker.mission(mission).missionID, "ms_a1")
    }
}

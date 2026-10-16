import XCTest
import MatronJournal
import MatronEvents
@testable import MatronChat

/// Person-to-person consent cards used to fall through to the generic
/// `permission_request` branch: an Allow/Deny prompt whose taps went out as
/// `prompt_reply`, which nothing reads. They now map to an inert people card
/// that points at the tracker mirror, the one place they are answered.
final class JournalTimelineMapperPeopleCardTests: XCTestCase {
    private let server = URL(string: "https://chat.example.com")!

    private func map(_ payload: [String: Any], seq: Int64 = 40, sender: String = "journal") -> TimelineItem? {
        let event = JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: 1000),
                                 sender: sender, type: "permission_request",
                                 payloadData: try! JSONSerialization.data(withJSONObject: payload))
        return JournalTimelineMapper.timelineItem(from: event, ownSender: "user:alice", serverURL: server)
    }

    private func peopleCard(_ item: TimelineItem?, file: StaticString = #filePath, line: UInt = #line)
        -> (eventID: String, card: PersonConsentCard)? {
        guard let item else { XCTFail("no row", file: file, line: line); return nil }
        guard case .personConsentCard(let eventID, let card) = item.kind else {
            XCTFail("expected a people card, got \(item.kind)", file: file, line: line)
            return nil
        }
        return (eventID, card)
    }

    func testEveryPeopleKindMapsToAPeopleCardNeverAPrompt() {
        let payloads: [[String: Any]] = [
            ["kind": "contact_request", "direction": "in", "contact_id": "ct_1", "peer": ["name": "alice"]],
            ["kind": "contact_request", "direction": "out", "contact_id": "ct_2", "peer": ["name": "bob"],
             "from_device_id": 3, "from_name": "box-a"],
            ["kind": "mission_share", "direction": "in", "grant_id": "gr_1",
             "owner": ["name": "alice"], "grantee": ["name": "bob"], "mission": ["title": "Cover editor"]],
            ["kind": "session_share", "direction": "out", "session_share_id": "ss_1",
             "person": ["name": "bob"], "session_title": "release notes"],
            ["kind": "person_room", "direction": "in", "room_link_id": "pr_1",
             "person": ["name": "alice"], "topic": "the cover editor"],
            ["kind": "person_room", "direction": "in", "room_link_id": "pr_2", "talk": true,
             "person": ["name": "alice"], "topic": "the cover editor", "session_title": NSNull(),
             "contact_pending": true, "choices": ["New session", "Decline"]],
        ]
        for payload in payloads {
            let item = map(payload)
            if case .askUser = item?.kind {
                XCTFail("\(payload["kind"]!) must not render as an Allow/Deny prompt")
            }
            XCTAssertNotNil(peopleCard(item), "\(payload)")
        }
    }

    func testTheCardKeepsItsSeqAsEventID() {
        guard let (eventID, card) = peopleCard(map([
            "kind": "person_room", "direction": "in", "room_link_id": "pr_1", "talk": true,
            "person": ["name": "alice"], "topic": "the cover editor",
        ], seq: 77)) else { return }
        XCTAssertEqual(eventID, "77")
        XCTAssertTrue(card.talk)
        XCTAssertEqual(card.headline, "alice's agent wants to talk.")
        XCTAssertEqual(card.mirror, .unknown, "the mapper sees one event; the mirror is found later")
    }

    /// A malformed people payload (no ids, no names) still gets the inert
    /// card, never the dead buttons.
    func testAMalformedPeoplePayloadIsStillInert() {
        XCTAssertNotNil(peopleCard(map(["kind": "mission_share"])))
    }

    /// The generic prompt is still there for the payloads it was meant for.
    func testAGenericPermissionRequestIsUnchanged() {
        guard case .askUser(_, let evt) = map(["description": "Run the migration?"])?.kind else {
            return XCTFail("expected the generic prompt")
        }
        XCTAssertEqual(evt.prompt, "Run the migration?")
    }
}

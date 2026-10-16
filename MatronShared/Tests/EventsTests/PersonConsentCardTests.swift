import XCTest
import MatronModels
@testable import MatronEvents

/// The journal's person-to-person consent cards (`contact_request`,
/// `mission_share`, `session_share`, `person_room`) are answered through
/// their tracker mirror, never from the card. The parser's one job is to
/// recognise every one of them, so none falls through to a generic prompt
/// with buttons nothing reads, and to pull out who, which way and what about.
final class PersonConsentCardTests: XCTestCase {

    // MARK: Contact requests

    func testOutgoingContactRequest() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: [
            "kind": "contact_request", "direction": "out", "contact_id": "ct_1",
            "peer": ["name": "bob", "address": "bob"],
            "from_device_id": 3, "from_name": "box-a", "from_convo_id": "c1",
        ]))
        XCTAssertEqual(card.kind, .contactRequest)
        XCTAssertEqual(card.direction, .outgoing)
        XCTAssertEqual(card.personName, "bob")
        XCTAssertEqual(card.askID, "ct_1")
        XCTAssertEqual(card.consentKind, "contact")
        XCTAssertEqual(card.consentLink, .contact(id: "ct_1"))
        XCTAssertEqual(card.title, "Contact request")
        XCTAssertEqual(card.headline, "Your agent asks to add bob as a contact.")
        XCTAssertNil(card.topic)
    }

    func testIncomingContactRequest() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: [
            "kind": "contact_request", "direction": "in", "contact_id": "ct_2",
            "peer": ["name": "alice", "address": "alice"],
        ]))
        XCTAssertEqual(card.direction, .incoming)
        XCTAssertEqual(card.personName, "alice")
        XCTAssertEqual(card.headline, "alice wants to add you as a contact.")
    }

    // MARK: Mission shares

    private func share(_ direction: String) -> [String: Any] {
        [
            "kind": "mission_share", "direction": direction, "grant_id": "gr_1", "level": "read",
            "owner": ["user_id": 1, "name": "alice"],
            "grantee": ["name": "bob", "address": "bob"],
            "mission": ["id": "m_1", "num": 4, "title": "Cover editor"],
            "preview": ["milestones": 2, "items": 3, "comments": 0, "attachments": 0],
        ]
    }

    func testOutgoingMissionShareNamesTheGrantee() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: share("out")))
        XCTAssertEqual(card.kind, .missionShare)
        XCTAssertEqual(card.personName, "bob")
        XCTAssertEqual(card.missionTitle, "Cover editor")
        XCTAssertEqual(card.consentLink, .share(id: "gr_1"))
        XCTAssertEqual(card.consentKind, "share")
        XCTAssertEqual(card.headline, "Your agent asks to share a mission with bob, read-only.")
    }

    func testIncomingMissionShareNamesTheOwner() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: share("in")))
        XCTAssertEqual(card.personName, "alice")
        XCTAssertEqual(card.headline, "alice wants to share a mission with you, read-only.")
    }

    // MARK: Session shares

    func testSessionShare() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: [
            "kind": "session_share", "direction": "out", "session_share_id": "ss_1",
            "person": ["name": "bob"], "session_title": "box-a:7f release notes",
            "from_device_id": 3, "from_name": "box-a",
        ]))
        XCTAssertEqual(card.kind, .sessionShare)
        XCTAssertEqual(card.personName, "bob")
        XCTAssertEqual(card.sessionTitle, "box-a:7f release notes")
        XCTAssertEqual(card.consentLink, .session(id: "ss_1"))
        XCTAssertEqual(card.consentKind, "session")
        XCTAssertEqual(card.headline, "Your agent asks to let bob's agents reach this session.")
    }

    // MARK: Rooms with another person

    private func room(_ direction: String, talk: Bool? = nil, extra: [String: Any] = [:]) -> [String: Any] {
        var payload: [String: Any] = [
            "kind": "person_room", "direction": direction, "room_link_id": "pr_1",
            "person": ["name": direction == "out" ? "bob" : "alice"],
            "session_title": "cover work", "topic": "the cover editor", "justification": "needs a second view",
            "mission": NSNull(),
        ]
        if let talk { payload["talk"] = talk }
        payload.merge(extra) { _, new in new }
        return payload
    }

    func testOutgoingRoom() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("out")))
        XCTAssertEqual(card.kind, .personRoom)
        XCTAssertFalse(card.talk)
        XCTAssertEqual(card.personName, "bob")
        XCTAssertEqual(card.topic, "the cover editor")
        XCTAssertEqual(card.sessionTitle, "cover work")
        XCTAssertNil(card.missionTitle, "a JSON null mission is no mission")
        XCTAssertEqual(card.consentLink, .room(id: "pr_1"))
        XCTAssertEqual(card.consentKind, "room")
        XCTAssertEqual(card.title, "Room with another person")
        XCTAssertEqual(card.headline, "Your agent asks to talk with bob's agent.")
    }

    func testIncomingRoom() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("in", extra: [
            "mission": ["num": NSNull(), "title": "Cover editor"],
        ])))
        XCTAssertEqual(card.personName, "alice")
        XCTAssertEqual(card.missionTitle, "Cover editor")
        XCTAssertEqual(card.headline, "alice's agent wants to talk with your agent.")
    }

    /// A talk request: one card per person, the extra fields the apps do not
    /// need must not break parsing, and no session is named until chosen.
    func testIncomingTalkRequest() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("in", talk: true, extra: [
            "session_title": NSNull(), "contact_pending": true,
            "choices": ["New session", "My Coordinator", "Pick a session", "Decline"],
        ])))
        XCTAssertTrue(card.talk)
        XCTAssertNil(card.sessionTitle)
        XCTAssertEqual(card.title, "Talk request")
        XCTAssertEqual(card.headline, "alice's agent wants to talk.")
        XCTAssertEqual(card.topic, "the cover editor")
    }

    func testOutgoingTalkRequest() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("out", talk: true, extra: [
            "session_title": NSNull(), "choices": ["Send", "Cancel"],
        ])))
        XCTAssertEqual(card.headline, "Your agent asks to talk with bob.")
    }

    // MARK: Degrading

    /// Missing ids and names still make a card — an inert one with no link —
    /// rather than nothing, or a generic prompt.
    func testAKnownKindWithNothingElseStillParses() throws {
        for kind in ["contact_request", "mission_share", "session_share", "person_room"] {
            let card = try XCTUnwrap(PersonConsentCard.parse(payload: ["kind": kind]), kind)
            XCTAssertNil(card.askID, kind)
            XCTAssertNil(card.consentLink, kind)
            XCTAssertEqual(card.direction, .incoming, kind)
            XCTAssertEqual(card.personName, "", kind)
            XCTAssertFalse(card.headline.isEmpty, kind)
        }
    }

    func testEmptyTopicIsNoTopic() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("out", extra: ["topic": "  "])))
        XCTAssertNil(card.topic)
    }

    func testOtherKindsAreNotPeopleCards() {
        XCTAssertNil(PersonConsentCard.parse(payload: ["kind": "agent_chat", "room_id": "r"]))
        XCTAssertNil(PersonConsentCard.parse(payload: ["kind": "agent_spawn"]))
        XCTAssertNil(PersonConsentCard.parse(payload: ["description": "Allow?"]))
        XCTAssertNil(PersonConsentCard.parse(payload: [:]))
    }

    // MARK: The mirror

    func testTheMirrorStartsUnknownAndCanBeAttached() throws {
        let card = try XCTUnwrap(PersonConsentCard.parse(payload: room("in", talk: true)))
        XCTAssertEqual(card.mirror, .unknown)
        let open = card.withMirror(.open(itemID: "it_1"))
        XCTAssertEqual(open.mirror, .open(itemID: "it_1"))
        XCTAssertEqual(open.mirror.itemID, "it_1")
        XCTAssertNil(PersonConsentCard.Mirror.unknown.itemID)
        XCTAssertEqual(PersonConsentCard.Mirror.closed(itemID: "it_2").itemID, "it_2")
        XCTAssertNotEqual(open, card)
    }
}

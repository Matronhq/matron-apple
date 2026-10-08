import XCTest
import MatronModels
@testable import MatronEvents

final class ItemMarkerEventTests: XCTestCase {
    func testParsesCommentedMarker() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "commented",
            "by": "user", "awaiting": "agent", "resolution": NSNull(),
            "comment": ["id": "ic_1", "body": "use A", "attachments": [["blob_ref": "b", "mime": "audio/mp4", "name": "v.m4a", "size": 1, "transcript": NSNull()]]],
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.num, 12); XCTAssertEqual(m.action, .commented); XCTAssertEqual(m.by, .user)
        XCTAssertEqual(m.awaiting, .agent); XCTAssertNil(m.resolution)
        XCTAssertEqual(m.comment?.body, "use A"); XCTAssertTrue(m.comment!.attachments[0].isAudio)
    }

    /// Comment action buttons (contract 2026-10-04): a tap's marker names
    /// the label and the comment whose buttons it answered.
    func testParsesATapOnACommentsButtons() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "commented",
            "by": "user", "awaiting": "agent", "resolution": NSNull(), "actions": [String](), "chosen_action": NSNull(),
            "comment": ["id": "ic_2", "body": "Go", "action": "Go", "reply_to": "ic_1", "actions": [String](),
                        "chosen_action": NSNull(), "attachments": [Any]()],
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.comment?.action, "Go")
        XCTAssertEqual(m.comment?.replyTo, "ic_1")
    }

    /// A typed reply, a tap on the item's own buttons, and a marker from a
    /// journal that predates either field.
    func testCommentWithoutATapOrAReplyToParsesAsNil() throws {
        var payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "commented", "by": "user",
            "comment": ["id": "ic_2", "body": "use A", "action": NSNull(), "reply_to": NSNull()],
        ]
        var m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertNil(m.comment?.action); XCTAssertNil(m.comment?.replyTo)
        payload["comment"] = ["id": "ic_2", "body": "Go", "action": "Go"]
        m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.comment?.action, "Go"); XCTAssertNil(m.comment?.replyTo)
    }

    func testRejectsUnknownActionOrMissingKeys() {
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["item_id": "it_1", "num": 1, "kind": "task", "title": "t", "action": "exploded", "by": "agent"]))
        XCTAssertNil(ItemMarkerEvent.parse(payload: ["num": 1, "kind": "task", "title": "t", "action": "created", "by": "agent"]))
    }

    func testParsesUpdatedMarker() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 3, "kind": "task", "title": "Ship it", "action": "updated", "by": "agent",
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.action, .updated)
    }

    /// A consent mirror's closing marker names its ask and how it ended
    /// (matron-journal `consent_ask` / `consent_outcome` / `decided_by`).
    func testParsesAConsentMirrorsAskAndOutcome() throws {
        let payload: [String: Any] = [
            "item_id": "it_9", "num": 9418, "kind": "question", "title": "hub-box asks to chat with oak",
            "action": "closed", "by": "agent", "resolution": "decided", "consent": "chat",
            "consent_ask": "room-1/7", "consent_outcome": "approved", "decided_by": "coordinator",
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertEqual(m.consent, "chat"); XCTAssertEqual(m.consentAsk, "room-1/7")
        XCTAssertEqual(m.consentOutcome, "approved"); XCTAssertEqual(m.decidedBy, "coordinator")
    }

    func testAnOrdinaryMarkerHasNoConsentFields() throws {
        let payload: [String: Any] = [
            "item_id": "it_1", "num": 12, "kind": "question", "title": "Which auth?", "action": "created", "by": "agent",
        ]
        let m = try XCTUnwrap(ItemMarkerEvent.parse(payload: payload))
        XCTAssertNil(m.consent); XCTAssertNil(m.consentAsk); XCTAssertNil(m.consentOutcome); XCTAssertNil(m.decidedBy)
    }

    /// The card the timeline keeps per item shows the item's latest state.
    func testRestatedTakesTheLatestState() {
        let created = ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q", action: .created,
                                      by: .agent, awaiting: .user)
        XCTAssertEqual(created.restated(as: created), created)

        let commented = ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q2", action: .commented,
                                        by: .user, awaiting: .agent)
        let open = created.restated(as: commented)
        XCTAssertEqual(open.action, .created); XCTAssertEqual(open.awaiting, .agent); XCTAssertEqual(open.title, "Q2")

        let closed = ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q", action: .closed, by: .user,
                                     resolution: .answered, comment: .init(id: "c", body: "Done."))
        let reopened = ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q", action: .reopened,
                                       by: .user, awaiting: .agent)
        let back = closed.restated(as: reopened)
        XCTAssertEqual(back.action, .created); XCTAssertNil(back.resolution); XCTAssertNil(back.comment)
        XCTAssertEqual(back.awaiting, .agent)

        // A reply on a closed item leaves it closed, closing note and all.
        let lateReply = ItemMarkerEvent(itemID: "it_1", num: 1, kind: .question, title: "Q", action: .commented,
                                        by: .user, resolution: .answered)
        XCTAssertEqual(closed.restated(as: lateReply), closed)
    }
}

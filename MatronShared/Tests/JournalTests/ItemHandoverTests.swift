import XCTest
import MatronModels
@testable import MatronJournal

/// An item's pending `handover` offer, and the caption the item detail
/// draws for it below the owner row.
final class ItemHandoverTests: XCTestCase {
    private func json(handover: Any?) -> [String: Any] {
        var json: [String: Any] = ["id": "it_1", "num": 1, "kind": "task", "state": "open", "title": "A task",
                                   "origin_convo_id": "c1", "created_at": 1_000, "updated_at": 2_000]
        if let handover { json["handover"] = handover }
        return json
    }

    private let expiry = Date(timeIntervalSince1970: 60)

    func testAnOfferParses() throws {
        let item = try XCTUnwrap(TrackerItem(json: json(handover: [
            "state": "offered", "to_convo_id": "c2", "to_convo_title": "Review changes", "expires_at": 60_000,
        ])))
        XCTAssertEqual(item.handover, ItemHandover(state: .offered, toConvoID: "c2", toConvoTitle: "Review changes",
                                                   expiresAt: expiry))
        let waiting = try XCTUnwrap(TrackerItem(json: json(handover: [
            "state": "awaiting_user", "to_convo_id": "c2", "to_convo_title": NSNull(), "expires_at": 60_000,
        ])))
        XCTAssertEqual(waiting.handover?.state, .awaitingUser)
        XCTAssertNil(waiting.handover?.toConvoTitle)
    }

    func testNoOfferIsNil() throws {
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(handover: NSNull()))).handover)
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(handover: nil))).handover, "a journal that predates the field")
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(handover: [
            "state": "declined", "to_convo_id": "c2", "expires_at": 60_000,
        ]))).handover, "a state this build does not know draws nothing")
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(handover: [
            "state": "offered", "to_convo_id": "c2",
        ]))).handover, "an offer with no expiry is malformed")
    }

    func testTheCaptionNamesTheTargetAndWhoIsBeingWaitedFor() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(ItemHandover(state: .offered, toConvoID: "c2", toConvoTitle: "Review changes", expiresAt: expiry)
            .caption(at: now), "Offered to Review changes · waiting for them to accept")
        XCTAssertEqual(ItemHandover(state: .awaitingUser, toConvoID: "c2", toConvoTitle: "Review changes", expiresAt: expiry)
            .caption(at: now), "Offered to Review changes · waiting for your OK")
        for title in [nil, "", "   "] {
            XCTAssertEqual(ItemHandover(state: .offered, toConvoID: "c2", toConvoTitle: title, expiresAt: expiry)
                .caption(at: now), "Offered to Conversation · waiting for them to accept")
        }
    }

    func testTheCaptionGoesAtExpiry() {
        let offer = ItemHandover(state: .offered, toConvoID: "c2", toConvoTitle: "Review changes", expiresAt: expiry)
        XCTAssertNotNil(offer.caption(at: expiry.addingTimeInterval(-1)))
        XCTAssertNil(offer.caption(at: expiry))
    }

    func testTheStoreKeepsTheOfferAndClearsItWhenSettled() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let offer = ItemHandover(state: .offered, toConvoID: "c2", toConvoTitle: "Review changes", expiresAt: expiry)
        func item(_ handover: ItemHandover?) -> TrackerItem {
            TrackerItem(id: "it_1", num: 1, kind: .task, title: "A task", originConvoID: "c1",
                        createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
                        handover: handover)
        }
        try store.upsertItems([item(offer)])
        XCTAssertEqual(try store.item(id: "it_1")?.handover, offer)
        try store.upsertItems([item(nil)])
        XCTAssertNil(try store.item(id: "it_1")?.handover)
    }
}

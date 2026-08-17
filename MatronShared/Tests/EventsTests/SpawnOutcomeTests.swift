import XCTest
@testable import MatronEvents

/// The durable resolution the whole spawn card design rests on: because this
/// arrives as a journal event, the card's answered state is read rather than
/// remembered.
final class SpawnOutcomeTests: XCTestCase {
    func test_parsesAStartedOutcome() throws {
        let outcome = try XCTUnwrap(SpawnOutcome.parse(payload: [
            "request_id": "spawn-1", "outcome": "started",
            "room_id": "room-9", "child_convo_id": "convo-9",
        ]))
        XCTAssertEqual(outcome.requestID, "spawn-1")
        XCTAssertEqual(outcome.kind, .started)
        XCTAssertEqual(outcome.roomID, "room-9")
        XCTAssertEqual(outcome.childConvoID, "convo-9")
        XCTAssertEqual(outcome.openableRoomID, "room-9")
        XCTAssertEqual(outcome.displayLine, "🚀 Spawned session started")
    }

    func test_displayLinesMatchTheServersSnippets() throws {
        let expected: [(String, String)] = [
            ("started", "🚀 Spawned session started"),
            ("declined", "🚫 Spawn declined"),
            ("expired", "⌛ Spawn request expired"),
            ("failed", "❌ Spawn failed"),
        ]
        for (raw, line) in expected {
            let outcome = try XCTUnwrap(
                SpawnOutcome.parse(payload: ["request_id": "s", "outcome": raw]))
            XCTAssertEqual(outcome.displayLine, line)
        }
    }

    func test_failedNamesItsErrorCodeWhenTheServerSentOne() throws {
        let outcome = try XCTUnwrap(SpawnOutcome.parse(payload: [
            "request_id": "s", "outcome": "failed", "error_code": "target_unreachable",
        ]))
        XCTAssertEqual(outcome.displayLine, "❌ Spawn failed — target_unreachable")
    }

    /// A newer server can mint an outcome this build has never heard of. It
    /// has to render as something neutral — never the raw wire value, and
    /// never a crash.
    func test_unknownOutcomeRendersNeutrally() throws {
        let outcome = try XCTUnwrap(SpawnOutcome.parse(payload: [
            "request_id": "s", "outcome": "conscripted",
        ]))
        XCTAssertNil(outcome.kind)
        XCTAssertEqual(outcome.outcome, "conscripted", "the wire value survives for logging")
        XCTAssertEqual(outcome.displayLine, "Spawn request resolved")
        XCTAssertNil(outcome.openableRoomID)
    }

    /// Nothing but a started spawn has a room, and offering to open one that
    /// was never created would push an empty conversation.
    func test_onlyAStartedOutcomeIsOpenable() throws {
        for raw in ["declined", "expired", "failed"] {
            let outcome = try XCTUnwrap(SpawnOutcome.parse(payload: [
                "request_id": "s", "outcome": raw, "room_id": "room-9",
            ]))
            XCTAssertNil(outcome.openableRoomID, "\(raw) must offer nothing to open")
        }
        let started = try XCTUnwrap(SpawnOutcome.parse(payload: [
            "request_id": "s", "outcome": "started",
        ]))
        XCTAssertNil(started.openableRoomID, "started without a room has nothing to open either")
    }

    func test_rejectsPayloadsThatResolveNothing() {
        XCTAssertNil(SpawnOutcome.parse(payload: ["outcome": "started"]))
        XCTAssertNil(SpawnOutcome.parse(payload: ["request_id": "s"]))
        XCTAssertNil(SpawnOutcome.parse(payload: ["request_id": "", "outcome": "started"]))
        XCTAssertNil(SpawnOutcome.parse(payload: ["request_id": "s", "outcome": ""]))
    }

    /// The synthetic resolution a 409 settles a card with. Not persisted
    /// anywhere — the real event replaces it as soon as it syncs.
    func test_syntheticExpiredCarriesTheRequestID() {
        let outcome = SpawnOutcome.expired(requestID: "spawn-1")
        XCTAssertEqual(outcome.requestID, "spawn-1")
        XCTAssertEqual(outcome.kind, .expired)
        XCTAssertEqual(outcome.displayLine, "⌛ Spawn request expired")
    }

    func test_parsesFromRealJSON() throws {
        let json = #"""
        {"request_id":"spawn-4","outcome":"started","room_id":"room-4","child_convo_id":"c4"}
        """#
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let outcome = try XCTUnwrap(SpawnOutcome.parse(payload: payload))
        XCTAssertEqual(outcome.openableRoomID, "room-4")
        XCTAssertEqual(outcome.childConvoID, "c4")
    }
}

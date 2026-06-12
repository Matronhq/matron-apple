import XCTest
import MatronEvents
@testable import MatronChat

/// Tests `TimelineSnapshotListener.parseCustomEvent(typeString:originalJson:eventID:)` —
/// the testable seam for Phase 5 Task 6's SDK-event → `TimelineItem.Kind`
/// mapping. The wrapping `mapMatronCustomEvent(_:)` (which extracts the
/// JSON via `EventTimelineItem.lazyProvider.debugInfo()`) can't be unit-
/// tested without a live SDK handle — the integration harness covers
/// that. These tests pin the JSON-shape contract that the bridge has to
/// satisfy and the graceful-degradation behaviour for malformed events.
final class TimelineServiceLiveCustomEventTests: XCTestCase {
    func test_parsesToolCallFromOriginalJson() {
        let json = #"""
        {
          "type": "chat.matron.tool_call",
          "content": {
            "tool": "Read",
            "args": {"file_path": "/etc/hosts"},
            "status": "running",
            "started_at": 1745000000000.0
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.tool_call",
            originalJson: json,
            eventID: "$evt:server"
        )
        guard case .toolCall(let id, let evt) = kind else {
            return XCTFail("Expected .toolCall, got \(String(describing: kind))")
        }
        XCTAssertEqual(id, "$evt:server")
        XCTAssertEqual(evt.tool, "Read")
        XCTAssertEqual(evt.status, .running)
    }

    func test_parsesAskUserFromOriginalJson() {
        let json = #"""
        {
          "type": "chat.matron.ask_user",
          "content": {
            "prompt": "Continue?",
            "input": {"kind": "boolean"}
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.ask_user",
            originalJson: json,
            eventID: "$ask:server"
        )
        guard case .askUser(let id, let evt) = kind else {
            return XCTFail("Expected .askUser, got \(String(describing: kind))")
        }
        XCTAssertEqual(id, "$ask:server")
        XCTAssertEqual(evt.prompt, "Continue?")
        XCTAssertEqual(evt.kind, .boolean)
    }

    func test_returnsNilForNonMatronType() {
        // A custom event type outside the Matron namespace — caller
        // falls through to the standard `.unknown(eventType:)` path.
        let json = #"{"type": "chat.other.thing", "content": {}}"#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.other.thing",
            originalJson: json,
            eventID: "$x"
        )
        XCTAssertNil(kind)
    }

    func test_returnsNilForMalformedJson() {
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.tool_call",
            originalJson: "{not json",
            eventID: "$x"
        )
        XCTAssertNil(kind)
    }

    func test_returnsNilWhenContentFieldMissing() {
        // JSON parses but has no top-level `content` field — bridge bug,
        // graceful-degrade to nil so the renderer falls through to
        // `.unknown(eventType:)`.
        let json = #"{"type": "chat.matron.tool_call"}"#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.tool_call",
            originalJson: json,
            eventID: "$x"
        )
        XCTAssertNil(kind)
    }

    func test_returnsNilWhenContentParseFails_toolCall() {
        // `content` is present but missing required fields (no
        // `started_at`). The per-type parser refuses; we propagate
        // nil rather than emitting a half-parsed `.toolCall` with
        // bogus defaults.
        let json = #"""
        {
          "type": "chat.matron.tool_call",
          "content": {"tool": "Read", "status": "running"}
        }
        """#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.tool_call",
            originalJson: json,
            eventID: "$x"
        )
        XCTAssertNil(kind)
    }

    func test_returnsNilWhenContentParseFails_askUser() {
        // Unknown input.kind — askUser parser refuses. Propagate nil.
        let json = #"""
        {
          "type": "chat.matron.ask_user",
          "content": {"prompt": "?", "input": {"kind": "alien"}}
        }
        """#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.ask_user",
            originalJson: json,
            eventID: "$x"
        )
        XCTAssertNil(kind)
    }

    func test_eventIDIsCarriedThrough() {
        // m.replace correlation: the same eventID input string lands
        // verbatim on the case's associated value so the SDK's replace
        // diff can find the matching row.
        let json = #"""
        {
          "type": "chat.matron.tool_call",
          "content": {
            "tool": "Read",
            "status": "ok",
            "result": "x",
            "started_at": 1745000000000.0,
            "ended_at": 1745000001000.0
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseCustomEvent(
            typeString: "chat.matron.tool_call",
            originalJson: json,
            eventID: "$specific-event-id:server"
        )
        guard case .toolCall(let id, _) = kind else {
            return XCTFail("Expected .toolCall")
        }
        XCTAssertEqual(id, "$specific-event-id:server")
    }

    // MARK: - parseButtonsMessage (Matron X buttons protocol)

    /// Wire shape per claude-matrix-bridge `sendButtonMessage`: plain
    /// m.room.message with the buttons dict under a content key.
    func test_parsesButtonsMessage_asAskUser() {
        let json = #"""
        {
          "type": "m.room.message",
          "content": {
            "msgtype": "m.text",
            "body": "Proceed? [Yes] [No]",
            "chat.matron.buttons": {
              "mode": "pick_one",
              "prompt": "Proceed?",
              "buttons": [
                {"id": "y", "label": "Yes", "value": "yes"},
                {"id": "n", "label": "No", "value": "no"}
              ]
            }
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseButtonsMessage(
            originalJson: json,
            eventID: "$btns:server"
        )
        guard case .askUser(let id, let evt) = kind else {
            return XCTFail("Expected .askUser, got \(String(describing: kind))")
        }
        XCTAssertEqual(id, "$btns:server")
        XCTAssertEqual(evt.prompt, "Proceed?")
        XCTAssertEqual(evt.replyChannel, .buttonResponse)
    }

    /// Wire shape per Matron X `TimelineController.sendButtonResponse`.
    func test_parsesButtonResponse_asAskUserAnswer() {
        let json = #"""
        {
          "type": "m.room.message",
          "content": {
            "msgtype": "m.text",
            "body": "yes",
            "chat.matron.button_response": {"selected_values": ["yes"]},
            "m.relates_to": {
              "rel_type": "chat.matron.button_answer",
              "event_id": "$btns:server"
            }
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseButtonsMessage(
            originalJson: json,
            eventID: "$resp:server"
        )
        guard case .askUserAnswer(let promptID, let values) = kind else {
            return XCTFail("Expected .askUserAnswer, got \(String(describing: kind))")
        }
        XCTAssertEqual(promptID, "$btns:server")
        XCTAssertEqual(values, ["yes"])
    }

    /// The bridge accepts a legacy `button_response: true` form (body
    /// carries the value). Matron X hides every button-response
    /// message regardless of shape — match that: still map to
    /// `.askUserAnswer`, just with nothing recoverable.
    func test_parsesLegacyBooleanButtonResponse_asAskUserAnswer() {
        let json = #"""
        {
          "type": "m.room.message",
          "content": {
            "msgtype": "m.text",
            "body": "yes",
            "chat.matron.button_response": true
          }
        }
        """#
        let kind = TimelineSnapshotListener.parseButtonsMessage(
            originalJson: json,
            eventID: "$resp:server"
        )
        guard case .askUserAnswer(let promptID, let values) = kind else {
            return XCTFail("Expected .askUserAnswer, got \(String(describing: kind))")
        }
        XCTAssertEqual(promptID, "")
        XCTAssertEqual(values, [])
    }

    func test_buttonsMessage_returnsNilForPlainText() {
        let json = #"""
        {
          "type": "m.room.message",
          "content": {"msgtype": "m.text", "body": "just chatting"}
        }
        """#
        XCTAssertNil(TimelineSnapshotListener.parseButtonsMessage(
            originalJson: json,
            eventID: "$x"
        ))
    }

    func test_buttonsMessage_returnsNilForMalformedButtonsDict() {
        // buttons key present but unparseable (no buttons array) —
        // graceful degradation to the plaintext `body` fallback the
        // bridge always includes.
        let json = #"""
        {
          "type": "m.room.message",
          "content": {
            "msgtype": "m.text",
            "body": "Pick one: A, B",
            "chat.matron.buttons": {"mode": "pick_one", "prompt": "Pick"}
          }
        }
        """#
        XCTAssertNil(TimelineSnapshotListener.parseButtonsMessage(
            originalJson: json,
            eventID: "$x"
        ))
    }
}

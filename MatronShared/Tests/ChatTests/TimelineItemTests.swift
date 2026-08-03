import XCTest
import MatronEvents
@testable import MatronChat

final class TimelineItemTests: XCTestCase {
    func test_textKind_equality() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        XCTAssertEqual(a, b)
    }

    func test_differentKinds_areInequal() {
        let a = TimelineItem.Kind.text(body: "hi", formattedHTML: nil)
        let b = TimelineItem.Kind.file(url: nil, filename: "x", caption: nil, sizeBytes: nil)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Phase 5 custom-event cases

    func test_toolCallKind_equality() {
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .running,
            resultText: nil, resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil
        )
        let a = TimelineItem.Kind.toolCall(eventID: "$1", evt)
        let b = TimelineItem.Kind.toolCall(eventID: "$1", evt)
        XCTAssertEqual(a, b)
    }

    func test_toolCallKind_differentEventID_isInequal() {
        // The case carries `eventID` so `m.replace` updates targeting
        // a specific event ID don't accidentally collapse to the same
        // case-equal value as a sibling toolCall event with identical
        // payload.
        let evt = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .running,
            resultText: nil, resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil
        )
        let a = TimelineItem.Kind.toolCall(eventID: "$1", evt)
        let b = TimelineItem.Kind.toolCall(eventID: "$2", evt)
        XCTAssertNotEqual(a, b)
    }

    func test_askUserKind_equality() {
        let evt = AskUserEvent(prompt: "Continue?", kind: .boolean, expiresAt: nil)
        let a = TimelineItem.Kind.askUser(eventID: "$ask", evt)
        let b = TimelineItem.Kind.askUser(eventID: "$ask", evt)
        XCTAssertEqual(a, b)
    }

    func test_toolCallKind_inequalToAskUserKind() {
        let tc = ToolCallEvent(
            tool: "Read", argsJSON: "{}", status: .ok,
            resultText: "x", resultTruncated: false,
            startedAt: Date(timeIntervalSince1970: 0), endedAt: nil
        )
        let au = AskUserEvent(prompt: "?", kind: .text, expiresAt: nil)
        let a = TimelineItem.Kind.toolCall(eventID: "$1", tc)
        let b = TimelineItem.Kind.askUser(eventID: "$1", au)
        XCTAssertNotEqual(a, b)
    }

    func test_id_isStable() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.id, "evt:1")
    }

    func test_sendState_defaultsToSent() {
        let item = TimelineItem(
            id: "evt:1",
            sender: "@a:s",
            timestamp: Date(timeIntervalSince1970: 0),
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: true
        )
        XCTAssertEqual(item.sendState, .sent)
    }

    func test_sendState_failed_carriesReason() {
        let a = TimelineItem.SendState.failed(reason: "network")
        let b = TimelineItem.SendState.failed(reason: "network")
        let c = TimelineItem.SendState.failed(reason: "auth")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

}

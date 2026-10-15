import XCTest
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronChat

final class JournalTimelineMapperSystemNoticeTests: XCTestCase {
    private let full = "🤝 A consent request is waiting for the user: \nchat ch_1 — alice asks to chat with bob\n"
        + "  consent_decide(kind: \"chat\", id: \"ch_1\", decision: approve|decline, reason: …)"

    private func map(_ payload: [String: Any]) -> TimelineItem? {
        JournalTimelineMapper.timelineItem(
            from: JournalEvent(seq: 33, convoID: "coord", ts: Date(timeIntervalSince1970: 1), sender: "agent:box-a",
                               type: JournalEventType.text,
                               payloadData: try! JSONSerialization.data(withJSONObject: payload)),
            ownSender: "user:alice", serverURL: URL(string: "https://j")!)
    }

    func testTaggedNoticeBecomesACompactRowKeepingTheFullText() throws {
        let item = try XCTUnwrap(map([
            "body": full, "from": "assistant",
            "notice": ["kind": "consent", "icon": "🤝", "summary": "alice → bob chat · artwork render · #12"],
        ]))
        guard case .systemNotice(let eventID, let notice) = item.kind else {
            return XCTFail("expected .systemNotice, got \(item.kind)")
        }
        XCTAssertEqual(eventID, "33")
        XCTAssertEqual(notice, SystemNoticeEvent(kind: "consent", icon: "🤝",
                                                 summary: "alice → bob chat · artwork render · #12", body: full))
        XCTAssertFalse(notice.summary.contains("consent_decide"))
    }

    func testUntaggedOrUnusableTagStaysText() throws {
        for payload: [String: Any] in [
            ["body": "Approved.", "from": "assistant"],
            ["body": "x", "notice": "consent"],
            ["body": "x", "notice": ["kind": "consent", "summary": "  \n "]],
        ] {
            let item = try XCTUnwrap(map(payload))
            guard case .text = item.kind else { return XCTFail("expected .text, got \(item.kind)") }
        }
    }

    func testSummaryIsFlattenedAndMissingFieldsFallBack() {
        let notice = SystemNoticeEvent.parse(payload: ["body": "b", "notice": ["summary": "line one\nline two"]])
        XCTAssertEqual(notice, SystemNoticeEvent(kind: "notice", icon: "ℹ️", summary: "line one line two", body: "b"))
    }
}

import XCTest
import MatronModels

final class SessionStatusTests: XCTestCase {
    func testApplyMergesPartsIndependently() {
        var status = SessionStatus()
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil, email: "dan@example.com", taskRef: "toolu_parent_1"))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertNil(status.limits)
        XCTAssertEqual(status.email, "dan@example.com")
        XCTAssertEqual(status.taskRef, "toolu_parent_1")

        // A limits-only frame must not clear model/context/email/taskRef.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil,
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: "soon", resetsAt: nil)],
            email: nil, taskRef: nil))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertEqual(status.limits?.count, 1)
        XCTAssertEqual(status.email, "dan@example.com")
        XCTAssertEqual(status.taskRef, "toolu_parent_1", "an absent task_ref must not clear a known one")

        // A newer context replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil,
            context: SessionStatus.Context(tokens: 200_000, window: 1_000_000, pct: 20),
            limits: nil, email: nil, taskRef: nil))
        XCTAssertEqual(status.context?.tokens, 200_000)
        XCTAssertEqual(status.limits?.count, 1)

        // A newer email replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: "other@example.com", taskRef: nil))
        XCTAssertEqual(status.email, "other@example.com")
    }
}

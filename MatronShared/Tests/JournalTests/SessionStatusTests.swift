import XCTest
import MatronModels

final class SessionStatusTests: XCTestCase {
    func testApplyMergesPartsIndependently() {
        var status = SessionStatus()
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil, email: "dan@example.com"))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertNil(status.limits)
        XCTAssertEqual(status.email, "dan@example.com")

        // A limits-only frame must not clear model/context/email.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil,
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: "soon", resetsAt: nil)],
            email: nil))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertEqual(status.limits?.count, 1)
        XCTAssertEqual(status.email, "dan@example.com")

        // A newer context replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil,
            context: SessionStatus.Context(tokens: 200_000, window: 1_000_000, pct: 20),
            limits: nil, email: nil))
        XCTAssertEqual(status.context?.tokens, 200_000)
        XCTAssertEqual(status.limits?.count, 1)

        // A newer email replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: "other@example.com"))
        XCTAssertEqual(status.email, "other@example.com")
    }
}

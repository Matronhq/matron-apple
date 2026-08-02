import XCTest
import MatronModels

final class SessionStatusTests: XCTestCase {
    func testApplyMergesPartsIndependently() {
        var status = SessionStatus()
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: "claude-fable-5",
            context: SessionStatus.Context(tokens: 100_000, window: 1_000_000, pct: 10),
            limits: nil, email: "dan@example.com", taskRef: "toolu_parent_1",
            workdir: "/Users/dan/Dev/matron-bridge",
            vitals: SessionStatus.Vitals(cpuPct: 12, ramPct: 63)))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertNil(status.limits)
        XCTAssertEqual(status.email, "dan@example.com")
        XCTAssertEqual(status.taskRef, "toolu_parent_1")
        XCTAssertEqual(status.workdir, "/Users/dan/Dev/matron-bridge")
        XCTAssertEqual(status.vitals, SessionStatus.Vitals(cpuPct: 12, ramPct: 63))

        // A limits-only frame must not clear model/context/email/taskRef/
        // workdir/vitals.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil,
            limits: [SessionStatus.Limit(label: "Session", percent: 39, resets: "soon", resetsAt: nil)],
            email: nil, taskRef: nil, workdir: nil, vitals: nil))
        XCTAssertEqual(status.model, "claude-fable-5")
        XCTAssertEqual(status.context?.pct, 10)
        XCTAssertEqual(status.limits?.count, 1)
        XCTAssertEqual(status.email, "dan@example.com")
        XCTAssertEqual(status.taskRef, "toolu_parent_1", "an absent task_ref must not clear a known one")
        XCTAssertEqual(status.workdir, "/Users/dan/Dev/matron-bridge", "an absent workdir must not clear a known one")
        XCTAssertEqual(status.vitals?.cpuPct, 12, "absent vitals must not clear known ones")

        // A newer context replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil,
            context: SessionStatus.Context(tokens: 200_000, window: 1_000_000, pct: 20),
            limits: nil, email: nil, taskRef: nil, workdir: nil, vitals: nil))
        XCTAssertEqual(status.context?.tokens, 200_000)
        XCTAssertEqual(status.limits?.count, 1)

        // A newer email replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: "other@example.com", taskRef: nil, workdir: nil, vitals: nil))
        XCTAssertEqual(status.email, "other@example.com")

        // Newer vitals replace old ones wholesale (they arrive as a pair —
        // a frame's vitals are one host sample, not two mergeable fields).
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: nil, taskRef: nil, workdir: nil,
            vitals: SessionStatus.Vitals(cpuPct: nil, ramPct: 71)))
        XCTAssertEqual(status.vitals, SessionStatus.Vitals(cpuPct: nil, ramPct: 71))
    }
}

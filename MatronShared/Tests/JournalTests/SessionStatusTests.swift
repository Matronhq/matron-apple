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
            vitals: SessionStatus.Vitals(cpuPct: 12, ramPct: 63),
            modelOptions: nil, effortLevels: nil, effort: nil))
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
            email: nil, taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
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
            limits: nil, email: nil, taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        XCTAssertEqual(status.context?.tokens, 200_000)
        XCTAssertEqual(status.limits?.count, 1)

        // A newer email replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: "other@example.com", taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        XCTAssertEqual(status.email, "other@example.com")

        // Newer vitals replace old ones wholesale (they arrive as a pair —
        // a frame's vitals are one host sample, not two mergeable fields).
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil,
            email: nil, taskRef: nil, workdir: nil,
            vitals: SessionStatus.Vitals(cpuPct: nil, ramPct: 71),
            modelOptions: nil, effortLevels: nil, effort: nil))
        XCTAssertEqual(status.vitals, SessionStatus.Vitals(cpuPct: nil, ramPct: 71))
    }

    /// The session-derived argument lists and the effort level merge like
    /// every other field: a frame that omits one leaves the previous value
    /// standing. Absent and empty are distinct and must not be conflated —
    /// absent means "this bridge doesn't say", empty means "this agent
    /// offers nothing" — so an empty list overwrites a held one.
    func testApplyMergesOptionListsAndEffort() {
        var status = SessionStatus()
        XCTAssertNil(status.modelOptions, "nothing said yet is absent, not empty")
        XCTAssertNil(status.effortLevels)
        XCTAssertNil(status.effort)

        status.apply(SessionStatusUpdate(
            convoID: "c1", model: "opus", context: nil, limits: nil, email: nil,
            taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: [SessionStatus.Option(value: "opus", label: "Opus")],
            effortLevels: [SessionStatus.Option(value: "high", label: "High")],
            effort: "high"))
        XCTAssertEqual(status.modelOptions?.map(\.value), ["opus"])
        XCTAssertEqual(status.effortLevels?.map(\.value), ["high"])
        XCTAssertEqual(status.effort, "high")

        // A frame carrying none of the three leaves all three standing —
        // the bridge publishes the lists on session start, not every turn.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil, email: nil,
            taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: nil))
        XCTAssertEqual(status.modelOptions?.map(\.value), ["opus"],
                       "an absent model_options must not clear a known list")
        XCTAssertEqual(status.effortLevels?.map(\.value), ["high"])
        XCTAssertEqual(status.effort, "high", "an absent effort must not clear a known one")

        // An empty list is a statement, not silence: this agent offers
        // nothing, so the held list goes.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil, email: nil,
            taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: [], effortLevels: nil, effort: nil))
        XCTAssertEqual(status.modelOptions, [], "an empty list replaces a held one")
        XCTAssertNotNil(status.modelOptions, "empty must not decay into absent")
        XCTAssertEqual(status.effortLevels?.map(\.value), ["high"])

        // A newer effort replaces the old one.
        status.apply(SessionStatusUpdate(
            convoID: "c1", model: nil, context: nil, limits: nil, email: nil,
            taskRef: nil, workdir: nil, vitals: nil,
            modelOptions: nil, effortLevels: nil, effort: "max"))
        XCTAssertEqual(status.effort, "max")
    }
}

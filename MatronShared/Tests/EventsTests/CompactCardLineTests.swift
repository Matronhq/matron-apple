import XCTest
@testable import MatronEvents

/// The one quiet line a bulky timeline card folds to: a reminder's Send
/// now / Cancel card always, a consent card once it is answered.
final class CompactCardLineTests: XCTestCase {
    private func reminder(_ prompt: String, id: Int = 7) -> AskUserEvent {
        AskUserEvent(
            prompt: prompt,
            kind: .choice(options: [
                .init(id: "timer-send-\(id)", label: "📤 Send now", value: "timer:send:\(id)"),
                .init(id: "timer-cancel-\(id)", label: "🚫 Cancel timer", value: "timer:cancel:\(id)"),
            ], allowOther: false),
            expiresAt: nil, replyChannel: .buttonResponse)
    }

    func testAReminderCardIsOneLineWithItsGlyphAsTheIcon() {
        let event = reminder("⏰ The agent set itself reminder #12 — in 10m:\n\"Check the build on box-a.\"")
        XCTAssertTrue(event.isReminderCard)
        XCTAssertEqual(event.compactLine,
                       CompactCardLine(icon: "⏰", summary: "The agent set itself reminder #12 — in 10m: \"Check the build on box-a.\"",
                                       status: nil))
    }

    func testAReminderWithoutAGlyphGetsTheClock() {
        XCTAssertEqual(reminder("Reminder #3 in 2h").compactLine.icon, "⏰")
        XCTAssertEqual(reminder("Reminder #3 in 2h").compactLine.summary, "Reminder #3 in 2h")
    }

    func testOtherAsksAreNotReminderCards() {
        let queued = AskUserEvent(
            prompt: "Message queued. Send now or cancel?",
            kind: .choice(options: [
                .init(id: "s", label: "Send", value: "send:0"),
                .init(id: "c", label: "Cancel", value: "cancel:0"),
            ], allowOther: false),
            expiresAt: nil, replyChannel: .buttonResponse)
        XCTAssertFalse(queued.isReminderCard)
        XCTAssertFalse(AskUserEvent(prompt: "Name?", kind: .text, expiresAt: nil).isReminderCard)
        // One timer button among others is not the reminder card.
        let mixed = AskUserEvent(
            prompt: "Pick",
            kind: .choice(options: [
                .init(id: "a", label: "A", value: "timer:send:1"),
                .init(id: "b", label: "B", value: "b"),
            ], allowOther: false),
            expiresAt: nil)
        XCTAssertFalse(mixed.isReminderCard)
    }

    private var spawn: AgentSpawnRequest {
        AgentSpawnRequest(requestID: "r1", fromDeviceID: 1, fromName: "box-a",
                          targetDeviceID: 2, targetName: "box-b",
                          task: "Run the release build\nand report back.")
    }

    func testAnOpenSpawnRequestStaysACard() {
        XCTAssertNil(spawn.compactLine(.idle))
        XCTAssertNil(spawn.compactLine(.sending))
        XCTAssertNil(spawn.compactLine(.failed("offline")))
    }

    func testAResolvedSpawnRequestFoldsToItsOutcome() {
        XCTAssertEqual(spawn.compactLine(.resolved(SpawnOutcome(requestID: "r1", outcome: "started", roomID: "!r"))),
                       CompactCardLine(icon: "🚀", summary: "Spawn on box-b: Run the release build", status: "Started"))
        XCTAssertEqual(spawn.compactLine(.resolved(SpawnOutcome(requestID: "r1", outcome: "declined")))?.status, "Declined")
        XCTAssertEqual(spawn.compactLine(.resolved(.expired(requestID: "r1")))?.icon, "⌛")
        XCTAssertEqual(spawn.compactLine(.resolved(SpawnOutcome(requestID: "r1", outcome: "failed", errorCode: "x")))?.status,
                       "Failed")
        XCTAssertEqual(spawn.compactLine(.resolved(SpawnOutcome(requestID: "r1", outcome: "approved")))?.status, "Approved")
        // An outcome this build does not know still folds.
        XCTAssertEqual(spawn.compactLine(.resolved(SpawnOutcome(requestID: "r1", outcome: "teleported"))),
                       CompactCardLine(icon: "✨", summary: "Spawn on box-b: Run the release build", status: "Resolved"))
    }

    private var chat: AgentChatRequest {
        AgentChatRequest(ask: .invite, roomID: "!r", fromDeviceID: 1, fromName: "box-a",
                         targetDeviceID: 2, toName: "box-b", topic: nil, justification: nil)
    }

    func testAnOpenChatRequestStaysACard() {
        XCTAssertNil(chat.compactLine(.idle))
        XCTAssertNil(chat.compactLine(.sending))
        XCTAssertNil(chat.compactLine(.failed("offline")))
    }

    func testAnAnsweredChatRequestFoldsToItsAnswer() {
        XCTAssertEqual(chat.compactLine(.answered(approved: true)),
                       CompactCardLine(icon: "👥", summary: "box-a wants to start a chat with box-b.", status: "Approved"))
        XCTAssertEqual(chat.compactLine(.answered(approved: false))?.status, "Declined")
        XCTAssertEqual(chat.compactLine(.answeredByCoordinator(approved: true))?.status, "Approved by the Coordinator")
        XCTAssertEqual(chat.compactLine(.answeredByCoordinator(approved: false))?.status, "Declined by the Coordinator")
        XCTAssertEqual(chat.compactLine(.expired)?.status, "No longer waiting")
    }
}

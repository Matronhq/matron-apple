import XCTest
import MatronChat
import MatronEvents
import MatronJournal
import MatronModels
@testable import MatronViewModels

private final class RecordingAnswerer: AgentChatAnswering, @unchecked Sendable {
    var error: Error?
    private(set) var calls: [(roomID: String, targetDeviceID: Int64,
                              decision: AgentChatDecision)] = []
    private let lock = NSLock()

    @discardableResult
    func answerAgentChat(roomID: String, targetDeviceID: Int64,
                         decision: AgentChatDecision) async throws -> Bool {
        lock.withLock { calls.append((roomID, targetDeviceID, decision)) }
        if let error { throw error }
        return true
    }
}

private let request = AgentChatRequest(
    ask: .invite, roomID: "room-1", fromDeviceID: 4, fromName: "box-2",
    targetDeviceID: 7, topic: "ci", justification: "logs")

/// The consent card's answer path. Everything here exists because answering
/// is an HTTP call that leaves no journal event: nothing in the timeline can
/// tell the card it was answered, so the view model has to remember.
@MainActor
final class ChatViewModelAgentChatTests: XCTestCase {
    private func makeViewModel(
        roomID: String = #function, answerer: RecordingAnswerer? = RecordingAnswerer()
    ) -> (ChatViewModel, RecordingAnswerer?) {
        UserDefaults.standard.removeObject(forKey: "matron.agentChatAnswers.\(roomID)")
        let vm = ChatViewModel(roomID: roomID, timeline: FakeTimelineService(),
                               media: FakeMediaService(), agentChat: answerer)
        return (vm, answerer)
    }

    func test_approveSendsTheRoomAndTargetFromTheCard_andSticks() async {
        let (vm, answerer) = makeViewModel()
        XCTAssertEqual(vm.agentChatState("11"), .idle)

        await vm.answerAgentChat(eventID: "11", request: request, decision: .approve)

        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(answerer?.calls[0].roomID, "room-1")
        XCTAssertEqual(answerer?.calls[0].targetDeviceID, 7)
        XCTAssertEqual(answerer?.calls[0].decision, .approve)
        XCTAssertEqual(vm.agentChatState("11"), .answered(approved: true))
    }

    func test_denyRecordsTheDecline() async {
        let (vm, answerer) = makeViewModel()
        await vm.answerAgentChat(eventID: "12", request: request, decision: .deny)
        XCTAssertEqual(answerer?.calls[0].decision, .deny)
        XCTAssertEqual(vm.agentChatState("12"), .answered(approved: false))
    }

    /// Push re-delivery and re-opening the room both re-render the card, and
    /// there is no answer event in the timeline to mark it resolved — without
    /// persistence the user would be asked the same question forever, and
    /// could answer it twice.
    func test_answersSurviveANewViewModelForTheSameRoom() async {
        let roomID = "persist-room"
        let (vm, _) = makeViewModel(roomID: roomID)
        await vm.answerAgentChat(eventID: "13", request: request, decision: .approve)

        let reopened = ChatViewModel(roomID: roomID, timeline: FakeTimelineService(),
                                     media: FakeMediaService(), agentChat: RecordingAnswerer())
        XCTAssertEqual(reopened.agentChatState("13"), .answered(approved: true))
        UserDefaults.standard.removeObject(forKey: "matron.agentChatAnswers.\(roomID)")
    }

    func test_answeringTwiceIsANoOp() async {
        let (vm, answerer) = makeViewModel()
        await vm.answerAgentChat(eventID: "14", request: request, decision: .approve)
        await vm.answerAgentChat(eventID: "14", request: request, decision: .deny)
        XCTAssertEqual(answerer?.calls.count, 1)
        XCTAssertEqual(vm.agentChatState("14"), .answered(approved: true))
    }

    /// 409 = the row stopped awaiting an answer: answered on another device,
    /// or 24h expired. Not a failure the user can retry, so the card settles
    /// as expired instead of offering buttons that will 409 again.
    func test_conflictSettlesTheCardAsExpired() async {
        let (vm, answerer) = makeViewModel()
        answerer?.error = JournalAPIError.conflict

        await vm.answerAgentChat(eventID: "15", request: request, decision: .approve)

        XCTAssertEqual(vm.agentChatState("15"), .expired)
    }

    /// A failed send must stay retryable — the decision genuinely was not
    /// recorded, so the card goes back to offering both buttons.
    func test_transportFailureLeavesTheCardAnswerable() async {
        let (vm, answerer) = makeViewModel()
        answerer?.error = JournalAPIError.transport("offline")

        await vm.answerAgentChat(eventID: "16", request: request, decision: .approve)

        guard case .failed(let message) = vm.agentChatState("16") else {
            return XCTFail("expected .failed, got \(vm.agentChatState("16"))")
        }
        XCTAssertTrue(message.contains("connection"))

        answerer?.error = nil
        await vm.answerAgentChat(eventID: "16", request: request, decision: .approve)
        XCTAssertEqual(vm.agentChatState("16"), .answered(approved: true))
    }

    /// No answerer wired (previews, tests, a host that hasn't passed one):
    /// render the card read-only rather than draw buttons that silently do
    /// nothing — which is exactly the bug this change removes.
    func test_withoutAnAnswererTheCardOffersNoButtons() async {
        let (vm, _) = makeViewModel(answerer: nil)
        XCTAssertEqual(vm.agentChatState("17"), .expired)
        await vm.answerAgentChat(eventID: "17", request: request, decision: .approve)
        XCTAssertEqual(vm.agentChatState("17"), .expired)
    }

    // MARK: Decided elsewhere

    private func startedViewModel(
        roomID: String = #function, items: [TimelineItem], answerer: RecordingAnswerer? = RecordingAnswerer()
    ) async -> ChatViewModel {
        UserDefaults.standard.removeObject(forKey: "matron.agentChatAnswers.\(roomID)")
        let timeline = FakeTimelineService()
        timeline.snapshotsToEmit = [items]
        let vm = ChatViewModel(roomID: roomID, timeline: timeline,
                               media: FakeMediaService(), agentChat: answerer)
        let task = await vm.start()
        await task.value
        return vm
    }

    private func journalRow(_ seq: Int, _ kind: TimelineItem.Kind) -> TimelineItem {
        TimelineItem(id: String(seq), sender: "journal", timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
                     kind: kind, isOwn: false)
    }

    private func consentMarker(_ seq: Int, _ action: ItemMarkerEvent.Action, awaiting: ItemAwaiting? = nil,
                               resolution: ItemResolution? = nil, note: String? = nil) -> TimelineItem {
        journalRow(seq, .itemMarker(eventID: String(seq), ItemMarkerEvent(
            itemID: "it_9418", num: 9418, kind: .question, title: "hub-box asks to chat with oak",
            action: action, by: .agent, awaiting: awaiting, resolution: resolution,
            comment: note.map { .init(id: "c\(seq)", body: $0) }, consent: "chat")))
    }

    /// #9418 end to end through a snapshot: the Coordinator decided, so the
    /// card offers no buttons, says who decided, and the item shows once.
    func test_aCardTheCoordinatorDecidedOffersNoButtons_andItsItemShowsOnce() async {
        let vm = await startedViewModel(items: [
            journalRow(10, .agentChatRequest(eventID: "10", request)),
            consentMarker(11, .created, awaiting: .user),
            consentMarker(12, .closed, resolution: .decided,
                          note: "Approved by the Coordinator — follows the box rules. The invitation is on its way."),
            journalRow(13, .consentDecision(eventID: "13", ConsentDecisionEvent(
                kind: .chat, decision: .approve, reason: "follows the box rules", askID: request.askID))),
        ])

        XCTAssertEqual(vm.agentChatState("10"), .answeredByCoordinator(approved: true))
        let itemRows = vm.rows.compactMap { row -> String? in
            guard case .message(let item) = row, case .itemMarker = item.kind else { return nil }
            return item.id
        }
        XCTAssertEqual(itemRows, ["12"])
    }

    /// Decided on another device: no tap here, nothing remembered here, and
    /// the card still settles — and a tap here does not reach the server.
    func test_aCardDecidedOnAnotherDeviceSettles_andCannotBeAnsweredAgain() async {
        let answerer = RecordingAnswerer()
        let vm = await startedViewModel(items: [
            journalRow(10, .agentChatRequest(eventID: "10", request)),
            consentMarker(11, .created, awaiting: .user),
            consentMarker(12, .closed, resolution: .decided, note: "Declined."),
        ], answerer: answerer)

        XCTAssertEqual(vm.agentChatState("10"), .answered(approved: false))
        await vm.answerAgentChat(eventID: "10", request: request, decision: .approve)
        XCTAssertTrue(answerer.calls.isEmpty)
        XCTAssertEqual(vm.agentChatState("10"), .answered(approved: false))
    }

    func test_anUndecidedCardStaysAnswerable() async {
        let vm = await startedViewModel(items: [
            journalRow(10, .agentChatRequest(eventID: "10", request)),
            consentMarker(11, .created, awaiting: .user),
        ])
        XCTAssertEqual(vm.agentChatState("10"), .idle)
    }
}

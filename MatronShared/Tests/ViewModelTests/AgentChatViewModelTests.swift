import XCTest
import MatronEvents
import MatronJournal
@testable import MatronViewModels

/// Records every call and replays scripted outcomes, so the tests can pin
/// exactly what reaches the wire — the point of this whole change is that
/// the old path reached the wrong endpoint entirely.
private final class FakeAgentChatAPI: AgentChatProviding, @unchecked Sendable {
    var pending: [AgentChatPendingDTO] = []
    var pendingError: Error?
    var answerError: Error?
    private(set) var answers: [(roomID: String, targetDeviceID: Int64,
                                decision: AgentChatDecision)] = []
    private(set) var refreshCount = 0

    func agentChatPending() async throws -> [AgentChatPendingDTO] {
        refreshCount += 1
        if let pendingError { throw pendingError }
        return pending
    }

    @discardableResult
    func answerAgentChat(roomID: String, targetDeviceID: Int64,
                         decision: AgentChatDecision) async throws -> Bool {
        answers.append((roomID, targetDeviceID, decision))
        if let answerError { throw answerError }
        return true
    }
}

private func pendingRow(room: String = "room-1", target: Int64 = 7, initiator: Int64 = 4,
                        createdAt: Int64 = 1_000) -> AgentChatPendingDTO {
    AgentChatPendingDTO(
        roomID: room, targetDeviceID: target, initiatorDeviceID: initiator,
        initiatorName: "dev-2", targetName: "dev-3", topic: "ci", justification: "logs",
        roomTitle: "dev-2 ↔ dev-3", createdAt: createdAt)
}

@MainActor
final class AgentChatViewModelTests: XCTestCase {
    func test_refreshLoadsPendingNewestFirst() async {
        let api = FakeAgentChatAPI()
        api.pending = [pendingRow(room: "old", createdAt: 1), pendingRow(room: "new", createdAt: 9)]
        let vm = AgentChatViewModel(api: api)

        await vm.refresh()

        XCTAssertEqual(vm.pending.map(\.roomID), ["new", "old"])
        XCTAssertTrue(vm.isSupported)
        XCTAssertNil(vm.errorMessage)
    }

    /// A journal that predates agent chat 404s the route. A permanently
    /// empty list would read as "you have nothing pending", which is a
    /// different and misleading claim.
    func test_serverWithoutAgentChatIsReportedAsUnsupported_notAsEmpty() async {
        let api = FakeAgentChatAPI()
        api.pendingError = JournalAPIError.notFound
        let vm = AgentChatViewModel(api: api)

        await vm.refresh()

        XCTAssertFalse(vm.isSupported)
        XCTAssertNil(vm.errorMessage, "an old server is not an error to shout about")
    }

    func test_answerSendsTheRowsOwnKeyAndRefreshes() async {
        let api = FakeAgentChatAPI()
        api.pending = [pendingRow(room: "room-9", target: 12)]
        let vm = AgentChatViewModel(api: api)
        await vm.refresh()

        await vm.answer(vm.pending[0], decision: .approve)

        XCTAssertEqual(api.answers.count, 1)
        XCTAssertEqual(api.answers[0].roomID, "room-9")
        XCTAssertEqual(api.answers[0].targetDeviceID, 12)
        XCTAssertEqual(api.answers[0].decision, .approve)
        XCTAssertEqual(api.refreshCount, 2, "the list must re-read after a decision")
    }

    /// 409 = the row stopped awaiting an answer between the list load and the
    /// tap (answered on another device, or 24h expired). Nothing the user can
    /// act on, so it refreshes the row away rather than showing an error they
    /// would only retry.
    func test_conflictIsResolvedQuietly() async {
        let api = FakeAgentChatAPI()
        api.pending = [pendingRow()]
        let vm = AgentChatViewModel(api: api)
        await vm.refresh()
        api.answerError = JournalAPIError.conflict
        api.pending = []

        await vm.answer(pendingRow(), decision: .deny)

        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.pending.isEmpty)
    }

    func test_answerFailureSurfacesAnError() async {
        let api = FakeAgentChatAPI()
        api.answerError = JournalAPIError.transport("offline")
        let vm = AgentChatViewModel(api: api)

        await vm.answer(pendingRow(), decision: .approve)

        XCTAssertNotNil(vm.errorMessage)
    }

    /// A join request self-targets, which is the only thing that tells the
    /// two shapes apart in the pending list — there is no `request` field.
    func test_headlineDistinguishesJoinFromInvite() {
        XCTAssertEqual(pendingRow(target: 7, initiator: 4).headline,
                       "dev-2 wants to start a chat with dev-3.")
        XCTAssertEqual(pendingRow(target: 4, initiator: 4).headline,
                       "dev-2 wants to join a chat.")
    }

    func test_missingNameFallsBackToTheDeviceID() {
        let row = AgentChatPendingDTO(
            roomID: "r", targetDeviceID: 7, initiatorDeviceID: 4,
            initiatorName: nil, targetName: nil, topic: nil, justification: nil,
            roomTitle: "", createdAt: 0)
        XCTAssertEqual(row.requesterLabel, "Device 4")
    }

    /// A failed refresh must leave the last good list standing rather than
    /// clearing it beside an error saying the load failed.
    func test_failedRefreshLeavesTheLastGoodListStanding() async {
        let api = FakeAgentChatAPI()
        api.pending = [pendingRow(room: "first")]
        let vm = AgentChatViewModel(api: api)
        await vm.refresh()

        api.pending = [pendingRow(room: "second")]
        api.pendingError = JournalAPIError.transport("offline")
        await vm.refresh()

        XCTAssertEqual(vm.pending.map(\.roomID), ["first"])
        XCTAssertNotNil(vm.errorMessage)
    }

    /// `refresh()` runs from `.task`, i.e. after the first frame — an
    /// unguarded empty list tells the user they have no pending requests a
    /// beat before their pending requests appear.
    func test_hasLoadedIsFalseUntilTheFirstLoadSettles() async {
        let api = FakeAgentChatAPI()
        let vm = AgentChatViewModel(api: api)
        XCTAssertFalse(vm.hasLoaded)

        api.pendingError = JournalAPIError.transport("offline")
        await vm.refresh()
        XCTAssertFalse(vm.hasLoaded, "a failed load has not established that the lists are empty")

        api.pendingError = nil
        await vm.refresh()
        XCTAssertTrue(vm.hasLoaded)
    }

    /// The state the screens read to tell "still fetching" from "tried and
    /// failed". Both look like `hasLoaded == false`, and a spinner shown for
    /// the second one claims we are still trying when we have already given up.
    func test_failedFirstLoadIsNotStillLoading() async {
        let api = FakeAgentChatAPI()
        api.pendingError = JournalAPIError.transport("offline")
        let vm = AgentChatViewModel(api: api)

        await vm.refresh()

        XCTAssertFalse(vm.hasLoaded)
        XCTAssertFalse(vm.isLoading, "a spinner here would outlive the attempt it stands for")
        XCTAssertNotNil(vm.errorMessage, "which leaves the error and its retry as the whole screen")
    }
}

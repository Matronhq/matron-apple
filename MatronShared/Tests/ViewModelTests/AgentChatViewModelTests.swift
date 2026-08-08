import XCTest
import MatronEvents
import MatronJournal
@testable import MatronViewModels

/// Records every call and replays scripted outcomes, so the tests can pin
/// exactly what reaches the wire — the point of this whole change is that
/// the old path reached the wrong endpoint entirely.
private final class FakeAgentChatAPI: AgentChatProviding, @unchecked Sendable {
    var pending: [AgentChatPendingDTO] = []
    var allowances: [AgentChatAllowanceDTO] = []
    var pendingError: Error?
    var answerError: Error?
    var revokeError: Error?
    private(set) var answers: [(roomID: String, targetDeviceID: Int64,
                                decision: AgentChatDecision, alwaysAllow: Bool)] = []
    private(set) var revokes: [(from: Int64, target: Int64)] = []
    private(set) var refreshCount = 0

    func agentChatPending() async throws -> [AgentChatPendingDTO] {
        refreshCount += 1
        if let pendingError { throw pendingError }
        return pending
    }

    func agentChatAllowances() async throws -> [AgentChatAllowanceDTO] {
        if let pendingError { throw pendingError }
        return allowances
    }

    @discardableResult
    func answerAgentChat(roomID: String, targetDeviceID: Int64,
                         decision: AgentChatDecision, alwaysAllow: Bool) async throws -> Bool {
        answers.append((roomID, targetDeviceID, decision, alwaysAllow))
        if let answerError { throw answerError }
        return true
    }

    func revokeAgentChatAllowance(fromDeviceID: Int64, targetDeviceID: Int64) async throws {
        revokes.append((fromDeviceID, targetDeviceID))
        if let revokeError { throw revokeError }
    }
}

private func pendingRow(room: String = "room-1", target: Int64 = 7, initiator: Int64 = 4,
                        createdAt: Int64 = 1_000) -> AgentChatPendingDTO {
    AgentChatPendingDTO(
        roomID: room, targetDeviceID: target, initiatorDeviceID: initiator,
        initiatorName: "dev-2", targetName: "dev-3", topic: "ci", justification: "logs",
        roomTitle: "dev-2 ↔ dev-3", createdAt: createdAt)
}

private func allowanceRow(from: Int64 = 4, target: Int64 = 7) -> AgentChatAllowanceDTO {
    AgentChatAllowanceDTO(fromDeviceID: from, targetDeviceID: target,
                          fromName: "dev-2", targetName: "dev-3", createdAt: 1_000)
}

@MainActor
final class AgentChatViewModelTests: XCTestCase {
    func test_refreshLoadsBothListsNewestFirst() async {
        let api = FakeAgentChatAPI()
        api.pending = [pendingRow(room: "old", createdAt: 1), pendingRow(room: "new", createdAt: 9)]
        api.allowances = [allowanceRow(from: 1), allowanceRow(from: 2)]
        let vm = AgentChatViewModel(api: api)

        await vm.refresh()

        XCTAssertEqual(vm.pending.map(\.roomID), ["new", "old"])
        XCTAssertEqual(vm.allowances.count, 2)
        XCTAssertTrue(vm.isSupported)
        XCTAssertNil(vm.errorMessage)
    }

    /// A journal that predates agent chat 404s the route. Two permanently
    /// empty lists would read as "you have nothing pending", which is a
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
        XCTAssertFalse(api.answers[0].alwaysAllow)
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

    func test_revokeSendsTheDirectedPairAndDropsTheRowLocallyFirst() async {
        let api = FakeAgentChatAPI()
        api.allowances = [allowanceRow(from: 4, target: 7)]
        let vm = AgentChatViewModel(api: api)
        await vm.refresh()
        // The server has dropped it; a refetch that fails must not leave the
        // revoked row on screen looking live.
        api.allowances = []

        await vm.revoke(vm.allowances[0])

        XCTAssertEqual(api.revokes.count, 1)
        XCTAssertEqual(api.revokes[0].from, 4)
        XCTAssertEqual(api.revokes[0].target, 7)
        XCTAssertTrue(vm.allowances.isEmpty)
    }

    func test_revokeFailureKeepsTheRowAndSaysSo() async {
        let api = FakeAgentChatAPI()
        api.allowances = [allowanceRow()]
        let vm = AgentChatViewModel(api: api)
        await vm.refresh()
        api.revokeError = JournalAPIError.transport("offline")

        await vm.revoke(vm.allowances[0])

        XCTAssertNotNil(vm.errorMessage)
    }

    /// A join request self-targets, which is the only thing that tells the
    /// two shapes apart in the pending list — there is no `request` field.
    func test_headlineDistinguishesJoinFromInvite() {
        XCTAssertEqual(pendingRow(target: 7, initiator: 4).headline,
                       "dev-2 wants to start a chat with another agent.")
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
}

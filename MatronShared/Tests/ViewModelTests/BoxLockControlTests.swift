import XCTest
import MatronModels
@testable import MatronJournal
@testable import MatronViewModels

private final class LockRPC: AgentRPCProviding, @unchecked Sendable {
    var calls: [(box: Int64, method: String, params: [String: Any])] = []
    var reply: RPCReply = .ok(resultData: Data("{}".utf8))
    func devices() async throws -> [DeviceDTO] { [] }
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply {
        calls.append((agentDeviceID, method, (try? JSONSerialization.jsonObject(with: paramsData)) as? [String: Any] ?? [:]))
        return reply
    }
    func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { _ in } }
}

private actor LockRequests {
    var seen: [ApprovalRequest] = []
    func add(_ r: ApprovalRequest) { seen.append(r) }
}

final class BoxLockControlTests: XCTestCase {
    private let box = DeviceDTO(id: 5, kind: "agent", name: "box-a", createdAt: 0, cursor: 0, lag: 0, lastSeenAt: nil,
                                isSelf: false, connected: true, locked: BoxLock(until: nil))
    private let approval = SignedApproval(statement: "{\"v\":1}", signature: "sig")

    func test_unlock_signsUnlockBoxWithTheMinutes_andSendsTheRPC() async {
        let rpc = LockRPC()
        let seen = LockRequests()
        let approval = self.approval
        let failure = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { request in
            await seen.add(request)
            return approval
        }
        XCTAssertNil(failure)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.kind, .account)
        XCTAssertEqual(requests.first?.subject, ["op": "unlock_box", "box": "box-a", "minutes": "30"])
        XCTAssertEqual(requests.first?.headline, "Unlock box-a for 30 minutes")
        XCTAssertEqual(rpc.calls.count, 1)
        XCTAssertEqual(rpc.calls[0].box, 5)
        XCTAssertEqual(rpc.calls[0].method, "unlock")
        XCTAssertEqual(rpc.calls[0].params["approval"] as? [String: String], ["statement": "{\"v\":1}", "signature": "sig"])
    }

    func test_clearLockdown_signsItsOwnStatement() async {
        let rpc = LockRPC()
        let seen = LockRequests()
        let approval = self.approval
        let failure = await BoxLockControl.clearLockdown(box: box, api: rpc) { request in
            await seen.add(request)
            return approval
        }
        XCTAssertNil(failure)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.subject, ["op": "clear_lockdown", "box": "box-a"])
        XCTAssertEqual(rpc.calls.first?.method, "clear_lockdown")
        XCTAssertNotNil(rpc.calls.first?.params["approval"])
    }

    func test_lock_needsNoSignature() async {
        let rpc = LockRPC()
        let failure = await BoxLockControl.lock(box: box, api: rpc)
        XCTAssertNil(failure)
        XCTAssertEqual(rpc.calls.first?.method, "lock")
        XCTAssertNil(rpc.calls.first?.params["approval"])
    }

    func test_unlock_cancelled_sendsNothing() async {
        let rpc = LockRPC()
        let failure = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in throw ApprovalKeyFailure.cancelled }
        XCTAssertEqual(failure, .cancelled)
        XCTAssertNil(failure?.text)
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func test_unlock_withNoKeyAtAll_isNeverSentUnsigned() async {
        let rpc = LockRPC()
        let failure = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in nil }
        XCTAssertTrue(failure?.text?.contains("approval key") ?? false)
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func test_boxRefusals_areSaidInWords() async {
        let rpc = LockRPC()
        let approval = self.approval
        func refusal(_ code: String, _ detail: String?) async -> BoxLockControl.Failure? {
            rpc.reply = .failure(code: code, detail: detail)
            return await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in approval }
        }
        let lockdown = await refusal("lockdown", nil)
        guard case .lockdown(let text) = lockdown else { return XCTFail("expected lockdown") }
        XCTAssertTrue(text.contains("lockdown"))
        let unknown = await refusal("approval_invalid", "unknown_key")
        XCTAssertTrue(unknown?.text?.contains("pinned") ?? false)
        let stale = await refusal("approval_invalid", "stale")
        XCTAssertEqual(stale?.text, JournalAPIError.approvalInvalidText("stale"))
        let tooLong = await refusal("bad_minutes", nil)
        XCTAssertTrue(tooLong?.text?.contains("shorter") ?? false)
        let unreachable = await refusal("agent_unreachable", nil)
        XCTAssertEqual(unreachable?.text, "box-a isn't connected.")
        let other = await refusal("weird", "why")
        XCTAssertEqual(other?.text, "box-a refused (weird: why).")
    }

    func test_texts() {
        XCTAssertEqual(BoxLockControl.defaultMinutes, 30)
        XCTAssertTrue(BoxLockControl.offeredMinutes.contains(30))
        XCTAssertEqual(BoxLockControl.durationText(15), "15 minutes")
        XCTAssertEqual(BoxLockControl.durationText(60), "1 hour")
        XCTAssertEqual(BoxLockControl.durationText(120), "2 hours")
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(BoxLockControl.stateText(BoxLock(until: nil), now: now), "Locked")
        XCTAssertEqual(BoxLockControl.stateText(BoxLock(until: now.addingTimeInterval(-5)), now: now), "Locked")
        XCTAssertEqual(BoxLockControl.stateText(BoxLock(until: now.addingTimeInterval(24 * 60 - 10)), now: now), "Unlocked for 24 more minutes")
        XCTAssertEqual(BoxLockControl.stateText(BoxLock(until: now.addingTimeInterval(40)), now: now), "Unlocked for under a minute")
    }
}

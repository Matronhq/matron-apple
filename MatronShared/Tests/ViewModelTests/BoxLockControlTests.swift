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

/// A roster with one box, an RPC answer to give, and a lock feed.
private final class LockedBoxes: BoxesProviding, @unchecked Sendable {
    var agents: [DeviceDTO]
    var reply: RPCReply = .ok(resultData: Data("{}".utf8))
    let feed = AsyncStream<(deviceID: Int64, lock: BoxLock?)>.makeStream()
    init(_ agents: [DeviceDTO]) { self.agents = agents }
    func devices() async throws -> [DeviceDTO] { agents }
    func roster() async throws -> RosterSnapshot { RosterSnapshot() }
    func agentRequest(agentDeviceID: Int64, method: String, paramsData: Data) async throws -> RPCReply { reply }
    func boxStatusUpdates() -> AsyncStream<(deviceID: Int64, status: BoxStatus)> { AsyncStream { _ in } }
    func connectionStates() -> AsyncStream<SyncConnectionState> { AsyncStream { _ in } }
    func boxLockUpdates() -> AsyncStream<(deviceID: Int64, lock: BoxLock?)> { feed.stream }
}

@MainActor
final class BoxesLockStateTests: XCTestCase {
    private let box = DeviceDTO(id: 5, kind: "agent", name: "box-a", createdAt: 0, cursor: 0, lag: 0, lastSeenAt: nil,
                                isSelf: false, connected: true, locked: BoxLock(on: true))

    private func lock(of viewModel: BoxesViewModel) -> BoxLock? {
        viewModel.rows().first { $0.id == 5 }?.device.locked
    }

    func test_theBoxesAnswer_isShownWithoutWaitingForTheRoster() async {
        let api = LockedBoxes([box])
        let viewModel = BoxesViewModel(api: api, capacityCache: InMemoryBoxCapacityCache())
        await viewModel.load()
        let until = Date().addingTimeInterval(600)
        let ms = Int64(until.timeIntervalSince1970 * 1000)
        api.reply = .ok(resultData: Data(#"{"locked":{"on":false,"until":\#(ms),"lockdown_until":null}}"#.utf8))
        viewModel.approvalSigner = { _ in SignedApproval(statement: "{}", signature: "sig") }
        let unlocked = await viewModel.unlock(box, minutes: 10)
        XCTAssertTrue(unlocked)
        // The roster still says "locked"; the box's own answer wins, and a
        // read straight after does not bring the old state back.
        XCTAssertEqual(lock(of: viewModel)?.isUnlocked(), true)
        await viewModel.load()
        XCTAssertEqual(lock(of: viewModel)?.isUnlocked(), true)
    }

    func test_aLiveFrame_changesTheBoxesLock_andLockdownShows() async {
        let api = LockedBoxes([box])
        let viewModel = BoxesViewModel(api: api, capacityCache: InMemoryBoxCapacityCache())
        await viewModel.load()
        let watch = Task { await viewModel.watch() }
        defer { watch.cancel() }
        let lockdown = BoxLock(on: true, lockdownUntil: Date().addingTimeInterval(900))
        api.feed.continuation.yield((deviceID: 5, lock: lockdown))
        for _ in 0..<200 where lock(of: viewModel) != lockdown { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(lock(of: viewModel), lockdown)
        XCTAssertTrue(viewModel.isInLockdown(viewModel.rows()[0].device))
        // The box stops checking approvals: nothing left to show.
        api.feed.continuation.yield((deviceID: 5, lock: nil))
        for _ in 0..<200 where lock(of: viewModel) != nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(viewModel.showsLock(viewModel.rows()[0].device))
    }

    func test_aBoxThatAnswersLockdown_showsIt_evenWhenTheServerDoesNotReportIt() async {
        let api = LockedBoxes([box])
        let viewModel = BoxesViewModel(api: api, capacityCache: InMemoryBoxCapacityCache())
        await viewModel.load()
        api.reply = .failure(code: "lockdown", detail: nil)
        viewModel.approvalSigner = { _ in SignedApproval(statement: "{}", signature: "sig") }
        let unlocked = await viewModel.unlock(box, minutes: 10)
        XCTAssertFalse(unlocked)
        XCTAssertTrue(viewModel.isInLockdown(box))
        // The box republishes its state without the lockdown field: the
        // answer it gave still counts.
        let watch = Task { await viewModel.watch() }
        defer { watch.cancel() }
        api.feed.continuation.yield((deviceID: 5, lock: BoxLock(on: true)))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(viewModel.isInLockdown(box))
    }
}

final class BoxLockControlTests: XCTestCase {
    private let box = DeviceDTO(id: 5, kind: "agent", name: "box-a", createdAt: 0, cursor: 0, lag: 0, lastSeenAt: nil,
                                isSelf: false, connected: true, locked: BoxLock(until: nil))
    private let approval = SignedApproval(statement: "{\"v\":1}", signature: "sig")

    func test_unlock_signsUnlockBoxWithTheMinutes_andSendsTheRPC() async {
        let rpc = LockRPC()
        let seen = LockRequests()
        let approval = self.approval
        let outcome = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { request in
            await seen.add(request)
            return approval
        }
        XCTAssertNil(outcome.failure)
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
        let outcome = await BoxLockControl.clearLockdown(box: box, api: rpc) { request in
            await seen.add(request)
            return approval
        }
        XCTAssertNil(outcome.failure)
        let requests = await seen.seen
        XCTAssertEqual(requests.first?.subject, ["op": "clear_lockdown", "box": "box-a"])
        XCTAssertEqual(rpc.calls.first?.method, "clear_lockdown")
        XCTAssertNotNil(rpc.calls.first?.params["approval"])
    }

    func test_lock_needsNoSignature() async {
        let rpc = LockRPC()
        let outcome = await BoxLockControl.lock(box: box, api: rpc)
        XCTAssertNil(outcome.failure)
        XCTAssertEqual(rpc.calls.first?.method, "lock")
        XCTAssertNil(rpc.calls.first?.params["approval"])
    }

    func test_unlock_cancelled_sendsNothing() async {
        let rpc = LockRPC()
        let outcome = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in throw ApprovalKeyFailure.cancelled }
        XCTAssertEqual(outcome.failure, .cancelled)
        XCTAssertNil(outcome.failure?.text)
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func test_unlock_withNoKeyAtAll_isNeverSentUnsigned() async {
        let rpc = LockRPC()
        let outcome = await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in nil }
        XCTAssertTrue(outcome.failure?.text?.contains("approval key") ?? false)
        XCTAssertTrue(rpc.calls.isEmpty)
    }

    func test_boxRefusals_areSaidInWords() async {
        let rpc = LockRPC()
        let approval = self.approval
        func refusal(_ code: String, _ detail: String?) async -> BoxLockControl.Failure? {
            rpc.reply = .failure(code: code, detail: detail)
            return await BoxLockControl.unlock(box: box, minutes: 30, api: rpc) { _ in approval }.failure
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
        let noLocking = await refusal("unknown_method", nil)
        XCTAssertEqual(noLocking?.text, "This box does not support locking.")
        let keysFile = await refusal("approval_invalid", "keys_file")
        XCTAssertTrue(keysFile?.text?.contains("file of approval keys") ?? false)
        let identity = await refusal("approval_invalid", "identity_unknown")
        XCTAssertTrue(identity?.text?.contains("which account") ?? false)
        let ledger = await refusal("approval_invalid", "nonce_ledger")
        XCTAssertEqual(ledger?.text, "box-a couldn't check the approval (nonce_ledger). Try again.")
        let reused = await refusal("approval_invalid", "nonce_reused")
        XCTAssertEqual(reused?.text, JournalAPIError.approvalInvalidText("nonce_reused"))
        let notLocked = await refusal("not_locked", nil)
        XCTAssertEqual(notLocked?.text, "box-a is not in locked mode.")
        let other = await refusal("weird", "why")
        XCTAssertEqual(other?.text, "box-a refused (weird: why).")
    }

    func test_theBoxAnswersWithItsNewState() async {
        let rpc = LockRPC()
        let approval = self.approval
        rpc.reply = .ok(resultData: Data(#"{"locked":{"on":false,"until":1790000600000,"lockdown_until":null}}"#.utf8))
        let unlocked = await BoxLockControl.unlock(box: box, minutes: 10, api: rpc) { _ in approval }
        XCTAssertEqual(unlocked, .done(BoxLock(on: false, until: Date(timeIntervalSince1970: 1_790_000_600))))
        rpc.reply = .ok(resultData: Data(#"{"locked":{"on":true,"until":null,"lockdown_until":null}}"#.utf8))
        let locked = await BoxLockControl.lock(box: box, api: rpc)
        XCTAssertEqual(locked, .done(BoxLock(on: true)))
        // An answer with no state still counts as done.
        rpc.reply = .ok(resultData: Data("{}".utf8))
        let bare = await BoxLockControl.lock(box: box, api: rpc)
        XCTAssertEqual(bare, .done(nil))
    }

    func test_lockStates_asTheBoxReportsThem() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func lock(_ json: String) -> BoxLock? {
            BoxLock.decode(try? JSONSerialization.jsonObject(with: Data(json.utf8)))
        }
        // No keys file: no `locked` key, or null.
        XCTAssertNil(BoxLock.decode(nil))
        XCTAssertNil(BoxLock.decode(NSNull()))
        // Locked.
        let locked = lock(#"{"on":true,"until":null,"lockdown_until":null}"#)
        XCTAssertEqual(locked, BoxLock(on: true))
        XCTAssertEqual(locked?.isShown(at: now), true)
        XCTAssertEqual(locked.map { BoxLockControl.stateText($0, now: now) }, "Locked")
        // An unlock window.
        let window = lock(#"{"on":false,"until":1790000600000,"lockdown_until":null}"#)
        XCTAssertEqual(window?.isUnlocked(at: now), true)
        XCTAssertEqual(window.map { BoxLockControl.stateText($0, now: now) }, "Unlocked for 10 more minutes")
        // A locked box in lockdown, and one that is not in locked mode.
        let lockdown = lock(#"{"on":true,"until":null,"lockdown_until":1790000900000}"#)
        XCTAssertEqual(lockdown?.isInLockdown(at: now), true)
        XCTAssertEqual(lockdown.map { BoxLockControl.stateText($0, now: now) }, "In lockdown")
        let openLockdown = lock(#"{"on":false,"until":null,"lockdown_until":1790000900000}"#)
        XCTAssertEqual(openLockdown?.isShown(at: now), true)
        XCTAssertEqual(openLockdown?.isInLockdown(at: now.addingTimeInterval(901)), false)
        // Checks approvals, neither locked nor in lockdown: nothing to show.
        let neither = lock(#"{"on":false,"until":null,"lockdown_until":null}"#)
        XCTAssertEqual(neither?.isShown(at: now), false)
        // A server that does not pass `lockdown_until` on.
        XCTAssertEqual(lock(#"{"on":true,"until":null}"#), BoxLock(on: true))
    }

    func test_accountLock_whatAStatusSays() {
        XCTAssertEqual(AccountLockMonitor.verdict(423), true)
        XCTAssertEqual(AccountLockMonitor.verdict(200), false)
        XCTAssertEqual(AccountLockMonitor.verdict(403), false)
        // A lock removes the device's sign-in: a refused token is no sign
        // that the lock was cleared.
        XCTAssertNil(AccountLockMonitor.verdict(401))
        XCTAssertNil(AccountLockMonitor.verdict(429))
        XCTAssertNil(AccountLockMonitor.verdict(503))
    }

    @MainActor
    func test_accountLock_fromTheSocket_staysUntilSignIn() async {
        let monitor = AccountLockMonitor()
        var cleared = 0
        monitor.whenCleared { cleared += 1 }
        monitor.noteLockedBySocket()
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(monitor.isLocked)
        monitor.note(status: 401)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(monitor.isLocked)
        // An answer sent before the lock, arriving after it.
        monitor.note(status: 200)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(monitor.isLocked)
        monitor.signedIn()
        XCTAssertFalse(monitor.isLocked)
        XCTAssertEqual(cleared, 1)
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

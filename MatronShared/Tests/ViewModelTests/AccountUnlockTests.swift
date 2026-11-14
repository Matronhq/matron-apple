import CryptoKit
import XCTest
import MatronAuth
import MatronStorage
import MatronModels
@testable import MatronJournal
@testable import MatronViewModels

/// A locked journal: every read is refused (423) except the nonce and the
/// unlock itself.
private actor LockedJournal: ApprovalKeysProviding, AccountUnlocking {
    var nonces = 0
    var unlocks: [SignedApproval] = []
    var unlockResult: Result<AccountUnlockResult, Error> = .success(AccountUnlockResult(token: "new-token", devicesRevoked: 2))

    func set(unlockResult: Result<AccountUnlockResult, Error>) { self.unlockResult = unlockResult }

    func approvalKeys() async throws -> ApprovalKeysState { throw JournalAPIError.accountLocked }
    func approvalNonce() async throws -> ApprovalNonce {
        nonces += 1
        return ApprovalNonce(nonce: "nonce-\(nonces)", expiresAt: Date().addingTimeInterval(300))
    }
    func enrolApprovalKey(publicKey: String, name: String, password: String, code: String) async throws -> ApprovalKeyDTO { throw JournalAPIError.accountLocked }
    func requestApprovalKey(publicKey: String, name: String) async throws -> String { throw JournalAPIError.accountLocked }
    func approveApprovalKeyRequest(id: String, approval: SignedApproval) async throws -> ApprovalKeyDTO { throw JournalAPIError.accountLocked }
    func revokeApprovalKey(keyID: String, approval: SignedApproval) async throws { throw JournalAPIError.accountLocked }
    func revokeApprovalKey(keyID: String, password: String, code: String) async throws { throw JournalAPIError.accountLocked }
    func attachApprovalKey(approval: SignedApproval) async throws -> ApprovalKeyDTO { throw JournalAPIError.accountLocked }

    func unlockAccount(approval: SignedApproval) async throws -> AccountUnlockResult {
        unlocks.append(approval)
        return try unlockResult.get()
    }
}

private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    var error: Error?
    func add(_ token: String) throws {
        try lock.withLock {
            tokens.append(token)
            if let error { throw error }
        }
    }
    var all: [String] { lock.withLock { tokens } }
}

@MainActor
final class AccountUnlockTests: XCTestCase {
    private let since: Int64 = 1_790_000_000_000
    private var journal: LockedJournal!
    private var store: ApprovalKeyStore!
    private var center: ApprovalCenter!
    private var monitor: AccountLockMonitor!
    private var tokens: TokenLog!
    private var pending: PendingUnlockStore!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        journal = LockedJournal()
        store = ApprovalKeyStore(store: MemorySessionStore(), host: "journal.example", user: "alice")
        try store.save(try SoftwareKeyProvider().create())
        let now = Date(timeIntervalSince1970: 1_790_000_100)
        center = ApprovalCenter(api: journal, keys: SoftwareKeyProvider(), store: store, user: "alice", deviceID: 3,
                                deviceName: "alice's iPhone", journalHost: "journal.example", now: { now })
        monitor = AccountLockMonitor()
        tokens = TokenLog()
        let suite = "AccountUnlockTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        let captured = defaults!
        pending = PendingUnlockStore(user: "alice", host: "journal.example", defaults: { captured })
    }

    private func model() -> AccountUnlockModel {
        let center = self.center!
        let tokens = self.tokens!
        return AccountUnlockModel(monitor: monitor, api: journal,
                                  sign: { since in try await center.signUnlock(since: since) },
                                  adoptToken: { token in try tokens.add(token) },
                                  pending: pending)
    }

    private func frozen() async {
        monitor.noteLockedBySocket(AccountLock(since: since, canUnlock: true))
        for _ in 0..<100 where !monitor.canUnlock { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Runs `unlock` and answers the confirm sheet as soon as it shows.
    private func unlock(_ model: AccountUnlockModel, confirm: Bool = true) async {
        let task = Task { await model.unlock() }
        for _ in 0..<400 where center.prompt == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if center.prompt != nil {
            if confirm { center.confirm() } else { center.cancel() }
        }
        await task.value
    }

    func test_monitor_saysWhetherThisDeviceCanUnlock() async {
        XCTAssertFalse(monitor.canUnlock)
        monitor.note(lock: AccountLock(since: since, canUnlock: false))
        for _ in 0..<100 where !monitor.isLocked { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(monitor.isLocked)
        XCTAssertFalse(monitor.canUnlock)
        await frozen()
        XCTAssertTrue(monitor.canUnlock)
        // A refusal without `since` keeps the one already known.
        monitor.note(lock: AccountLock(since: nil, canUnlock: true))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(monitor.lock?.since, since)
    }

    func test_aNonceAnswer_doesNotClearALockLearnedOverHTTP() async {
        monitor.note(lock: AccountLock(since: since, canUnlock: true))
        for _ in 0..<100 where !monitor.canUnlock { try? await Task.sleep(for: .milliseconds(5)) }
        monitor.note(status: 200)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(monitor.canUnlock)
        // A device that was signed out, not frozen: a 200 does clear it.
        monitor.note(lock: AccountLock(since: since, canUnlock: false))
        try? await Task.sleep(for: .milliseconds(50))
        monitor.note(status: 200)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(monitor.isLocked)
    }

    func test_unlock_signsClearPanicOverTheLocksStart_withoutReadingTheKeys() async throws {
        await frozen()
        let model = model()
        await unlock(model)
        XCTAssertEqual(model.phase, .idle)
        let sent = await journal.unlocks
        XCTAssertEqual(sent.count, 1)
        let statement = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent[0].statement.utf8)) as? [String: Any])
        XCTAssertEqual(statement["type"] as? String, "account")
        XCTAssertEqual(statement["journal"] as? String, "journal.example")
        XCTAssertEqual(statement["user"] as? String, "alice")
        XCTAssertEqual(statement["nonce"] as? String, "nonce-1")
        XCTAssertEqual(statement["subject"] as? [String: String], ["op": "clear_panic", "since": "1790000000000"])
        XCTAssertEqual(statement["key_id"] as? String, store.load()?.keyID)
        // The new token is taken, the lock is gone, nothing is left pending.
        XCTAssertEqual(tokens.all, ["new-token"])
        XCTAssertFalse(monitor.isLocked)
        XCTAssertFalse(pending.isPending)
    }

    func test_theSheetShowsWhatIsSigned() async throws {
        await frozen()
        let model = model()
        let task = Task { await model.unlock() }
        for _ in 0..<400 where center.prompt == nil { try? await Task.sleep(for: .milliseconds(5)) }
        let prompt = try XCTUnwrap(center.prompt)
        XCTAssertEqual(prompt.request.headline, "Unlock this account")
        XCTAssertEqual(prompt.request.subject, ["op": "clear_panic", "since": "1790000000000"])
        XCTAssertFalse(prompt.attachesFirst)
        XCTAssertTrue(prompt.request.detail?.contains("signed out") ?? false)
        center.cancel()
        await task.value
        // Backing out sends nothing and leaves the lock as it was.
        XCTAssertEqual(model.phase, .idle)
        let sent = await journal.unlocks
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(monitor.canUnlock)
        XCTAssertFalse(pending.isPending)
    }

    func test_aLostAnswer_leavesTheTryPending_forTheSignInScreen() async {
        await frozen()
        await journal.set(unlockResult: .failure(JournalAPIError.transport("timed out")))
        let model = model()
        await unlock(model)
        XCTAssertEqual(model.errorText, "Couldn't reach the server. Try again.")
        XCTAssertTrue(pending.isPending)
        XCTAssertTrue(tokens.all.isEmpty)
        XCTAssertTrue(monitor.isLocked)
    }

    func test_notLocked_clearsTheLock() async {
        await frozen()
        await journal.set(unlockResult: .failure(AccountUnlockError.notLocked))
        let model = model()
        await unlock(model)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(monitor.isLocked)
        XCTAssertFalse(pending.isPending)
    }

    func test_refusals_areSaidInWords() async {
        await frozen()
        await journal.set(unlockResult: .failure(JournalAPIError.approvalInvalid(reason: "mismatch")))
        let model = model()
        await unlock(model)
        XCTAssertEqual(model.errorText, JournalAPIError.approvalInvalidText("mismatch"))
        await journal.set(unlockResult: .failure(JournalAPIError.accountLocked))
        await unlock(model)
        XCTAssertTrue(model.errorText?.contains("can't unlock") ?? false)
    }

    func test_noStart_noTry() async {
        monitor.noteLockedBySocket(AccountLock(since: nil, canUnlock: true))
        for _ in 0..<100 where !monitor.isLocked { try? await Task.sleep(for: .milliseconds(5)) }
        let model = model()
        await model.unlock()
        XCTAssertNotNil(model.errorText)
        XCTAssertNil(center.prompt)
    }

    func test_noKeyOnThisDevice_saysSo() async {
        store.delete()
        await frozen()
        let model = model()
        await model.unlock()
        XCTAssertEqual(model.errorText, ApprovalError.noKeyOnThisDevice.localizedDescription)
    }

    func test_aTokenThatCannotBeSaved_isSaid_butTheLockIsCleared() async {
        await frozen()
        tokens.error = NSError(domain: "keychain", code: 1)
        let model = model()
        await unlock(model)
        // The warning outlives the locked screen.
        XCTAssertFalse(monitor.isLocked)
        XCTAssertEqual(monitor.warning, AccountUnlockModel.unsavedTokenWarning)
        monitor.dismissWarning()
        XCTAssertNil(monitor.warning)
    }

    func test_signInNotice_afterALostAnswer() {
        let session = UserSession(userID: "alice", deviceID: "3", homeserverURL: URL(string: "https://journal.example")!,
                                  accessToken: "t")
        let vm = SignInViewModel(auth: FakeAuthForVM(), deviceDisplayName: "Matron Tests", signedOutRemotely: session,
                                 accountLocked: true, unlockAnswerLost: true)
        XCTAssertEqual(vm.notice, PendingUnlockStore.lostAnswerNotice)
    }
}

import CryptoKit
import XCTest
import MatronAuth
import MatronStorage
@testable import MatronJournal
@testable import MatronViewModels

/// A journal that keeps approval keys in memory and records what it is sent.
actor FakeApprovalKeysAPI: ApprovalKeysProviding {
    var enabled = true
    var journal: String? = "journal.example"
    var keys: [ApprovalKeyDTO] = []
    var requests: [ApprovalKeyRequestDTO] = []
    var nonces = 0
    var attached: [SignedApproval] = []
    var approvedRequests: [(id: String, approval: SignedApproval)] = []
    var revoked: [(keyID: String, approval: SignedApproval?)] = []
    var enrolError: Error?
    var keysError: Error?
    /// The device the calling app is signed in as.
    var callerDeviceID: Int64 = 3

    func set(keys: [ApprovalKeyDTO]) { self.keys = keys }
    func set(requests: [ApprovalKeyRequestDTO]) { self.requests = requests }
    func set(enabled: Bool) { self.enabled = enabled; journal = enabled ? "journal.example" : nil }
    func set(enrolError: Error?) { self.enrolError = enrolError }
    func set(keysError: Error?) { self.keysError = keysError }

    func approvalKeys() async throws -> ApprovalKeysState {
        if let keysError { throw keysError }
        return ApprovalKeysState(enabled: enabled, journal: journal, keys: keys, requests: requests)
    }

    func approvalNonce() async throws -> ApprovalNonce {
        nonces += 1
        return ApprovalNonce(nonce: "nonce-\(nonces)", expiresAt: Date().addingTimeInterval(300))
    }

    func enrolApprovalKey(publicKey: String, name: String, password: String, code: String) async throws -> ApprovalKeyDTO {
        if let enrolError { throw enrolError }
        let raw = ApprovalKeyEncoding.data(base64URL: publicKey)!
        let key = ApprovalKeyDTO(keyID: ApprovalKeyEncoding.keyID(publicKey: raw), publicKey: publicKey, name: name,
                                 deviceID: callerDeviceID, enrolledVia: .password)
        keys.append(key)
        return key
    }

    func requestApprovalKey(publicKey: String, name: String) async throws -> String {
        let raw = ApprovalKeyEncoding.data(base64URL: publicKey)!
        requests.append(ApprovalKeyRequestDTO(id: "kr_1", keyID: ApprovalKeyEncoding.keyID(publicKey: raw), name: name))
        return "kr_1"
    }

    func approveApprovalKeyRequest(id: String, approval: SignedApproval) async throws -> ApprovalKeyDTO {
        approvedRequests.append((id, approval))
        let request = requests.first { $0.id == id }!
        requests.removeAll { $0.id == id }
        let key = ApprovalKeyDTO(keyID: request.keyID, name: request.name, deviceID: 9, enrolledVia: .device)
        keys.append(key)
        return key
    }

    func revokeApprovalKey(keyID: String, approval: SignedApproval) async throws {
        revoked.append((keyID, approval))
        markRevoked(keyID)
    }

    func revokeApprovalKey(keyID: String, password: String, code: String) async throws {
        revoked.append((keyID, nil))
        markRevoked(keyID)
    }

    private func markRevoked(_ keyID: String) {
        keys = keys.map {
            $0.keyID == keyID
                ? ApprovalKeyDTO(keyID: $0.keyID, publicKey: $0.publicKey, name: $0.name, deviceID: $0.deviceID,
                                 enrolledVia: $0.enrolledVia, createdAt: $0.createdAt, revokedAt: Date())
                : $0
        }
    }

    func attachApprovalKey(approval: SignedApproval) async throws -> ApprovalKeyDTO {
        attached.append(approval)
        let obj = try JSONSerialization.jsonObject(with: Data(approval.statement.utf8)) as! [String: Any]
        let keyID = obj["key_id"] as! String
        keys = keys.map {
            $0.keyID == keyID
                ? ApprovalKeyDTO(keyID: $0.keyID, publicKey: $0.publicKey, name: $0.name, deviceID: callerDeviceID,
                                 enrolledVia: $0.enrolledVia, createdAt: $0.createdAt, revokedAt: $0.revokedAt)
                : $0
        }
        return keys.first { $0.keyID == keyID }!
    }
}

/// A key store in memory.
final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()
    func set(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
    func get(key: String) throws -> String? { lock.withLock { values[key] } }
    func delete(key: String) throws { lock.withLock { values[key] = nil } }
}

@MainActor
final class ApprovalCenterTests: XCTestCase {
    private var api: FakeApprovalKeysAPI!
    private var store: ApprovalKeyStore!
    private var center: ApprovalCenter!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        api = FakeApprovalKeysAPI()
        store = ApprovalKeyStore(store: MemorySessionStore(), host: "journal.example", user: "alice")
        center = makeCenter()
    }

    private func makeCenter(provider: any ApprovalKeyProviding = SoftwareKeyProvider()) -> ApprovalCenter {
        let now = self.now
        return ApprovalCenter(api: api, keys: provider, store: store, user: "alice", deviceID: 3,
                              deviceName: "alice's iPhone", now: { now })
    }

    /// This device holds a key the account has, attached to `deviceID`.
    @discardableResult
    private func giveDeviceAKey(attachedTo deviceID: Int64? = 3) async throws -> StoredApprovalKey {
        let stored = try SoftwareKeyProvider().create()
        try store.save(stored)
        await api.set(keys: [ApprovalKeyDTO(keyID: stored.keyID, publicKey: ApprovalKeyEncoding.base64URL(stored.publicKey),
                                            name: "alice's iPhone", deviceID: deviceID)])
        return stored
    }

    private let request = ApprovalRequest(kind: .account, subject: ["op": "change_password"], headline: "Change password")

    /// Runs `sign` and answers the confirm sheet as soon as it shows.
    private func sign(_ request: ApprovalRequest, confirm: Bool = true) async throws -> SignedApproval? {
        let center = self.center!
        let task = Task { try await center.sign(request) }
        for _ in 0..<200 where center.prompt == nil && !task.isCancelled {
            try await Task.sleep(nanoseconds: 2_000_000)
            if center.prompt != nil { break }
        }
        if center.prompt != nil {
            if confirm { center.confirm() } else { center.cancel() }
        }
        return try await task.value
    }

    private func statement(_ approval: SignedApproval) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(approval.statement.utf8)) as? [String: Any])
    }

    // MARK: When nothing is signed

    func test_accountWithNoKey_goesUnsigned_andShowsNoSheet() async throws {
        let approval = try await center.sign(request)
        XCTAssertNil(approval)
        XCTAssertNil(center.prompt)
        let nonces = await api.nonces
        XCTAssertEqual(nonces, 0)
        XCTAssertEqual(center.status, .noAccountKey)
    }

    func test_accountWithOnlyRevokedKeys_goesUnsigned() async throws {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "old", deviceID: nil, revokedAt: now)])
        let approval = try await center.sign(request)
        XCTAssertNil(approval)
    }

    func test_accountHasAKey_thisDeviceHasNone_isAClearError() async {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "alice's Mac", deviceID: 8)])
        do {
            _ = try await center.sign(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .noKeyOnThisDevice)
        }
        XCTAssertEqual(center.status, .noDeviceKey)
    }

    func test_thisDevicesKeyWasRevoked_isAClearError() async throws {
        let stored = try await giveDeviceAKey()
        await api.set(keys: [ApprovalKeyDTO(keyID: stored.keyID, name: "alice's iPhone", deviceID: 3, revokedAt: now),
                             ApprovalKeyDTO(keyID: "bb", name: "alice's Mac", deviceID: 8)])
        do {
            _ = try await center.sign(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .keyRevoked)
        }
        XCTAssertEqual(center.status, .revoked)
    }

    func test_keysCannotBeRead_isNotSilentlyUnsigned() async throws {
        try await giveDeviceAKey()
        await api.set(keysError: JournalAPIError.transport("offline"))
        do {
            _ = try await center.sign(request)
            XCTFail("expected the read failure")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .transport("offline"))
        }
    }

    // MARK: Signing

    func test_sign_showsTheRequest_thenSignsAStatementTheKeyVerifies() async throws {
        let stored = try await giveDeviceAKey()
        let center = self.center!
        let task = Task { try await center.sign(self.request) }
        while center.prompt == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        // The sheet is up and nothing has been fetched or signed yet.
        XCTAssertEqual(center.prompt?.request, request)
        XCTAssertEqual(center.prompt?.fingerprint, ApprovalKeyEncoding.fingerprint(keyID: stored.keyID))
        XCTAssertEqual(center.prompt?.method, "Face ID")
        let before = await api.nonces
        XCTAssertEqual(before, 0, "the nonce's five minutes start when the user confirms")
        center.confirm()
        let signedOrNil = try await task.value
        let approval = try XCTUnwrap(signedOrNil)
        XCTAssertNil(center.prompt)

        let s = try statement(approval)
        XCTAssertEqual(s["type"] as? String, "account")
        XCTAssertEqual(s["journal"] as? String, "journal.example")
        XCTAssertEqual(s["user"] as? String, "alice")
        XCTAssertEqual(s["key_id"] as? String, stored.keyID)
        XCTAssertEqual(s["nonce"] as? String, "nonce-1")
        XCTAssertEqual((s["signed_at"] as? NSNumber)?.int64Value, 1_790_000_000_000)
        XCTAssertEqual(s["subject"] as? [String: String], ["op": "change_password"])
        XCTAssertEqual(s["v"] as? Int, 1)
        XCTAssertEqual(s.count, 8)

        let der = try XCTUnwrap(ApprovalKeyEncoding.data(base64URL: approval.signature))
        let pub = try P256.Signing.PublicKey(x963Representation: stored.publicKey)
        XCTAssertTrue(pub.isValidSignature(try P256.Signing.ECDSASignature(derRepresentation: der),
                                           for: Data(approval.statement.utf8)))
    }

    func test_sign_itemTap_carriesItemActionAndDigest() async throws {
        try await giveDeviceAKey()
        let digest = PromptDigest.item(title: "Deploy box-a", body: "Roll out the new build?")
        let signedOrNil = try await sign(ApprovalRequest(
            kind: .itemTap(itemID: "it_abc123", num: 7, replyTo: nil, action: "Approve", promptDigest: digest),
            subject: ["box": "box-a"], headline: "Deploy box-a", reference: "#7", button: "Approve"))
        let approval = try XCTUnwrap(signedOrNil)
        let s = try statement(approval)
        XCTAssertEqual(s["type"] as? String, "item_tap")
        XCTAssertEqual(s["action"] as? String, "Approve")
        XCTAssertEqual(s["prompt_digest"] as? String, digest)
        let item = try XCTUnwrap(s["item"] as? [String: Any])
        XCTAssertEqual(item["id"] as? String, "it_abc123")
        XCTAssertEqual(item["num"] as? Int, 7)
        XCTAssertTrue(item["reply_to"] is NSNull)
    }

    func test_cancel_throwsCancelled_andNothingIsFetched() async throws {
        try await giveDeviceAKey()
        do {
            _ = try await sign(request, confirm: false)
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? ApprovalKeyFailure, .cancelled)
        }
        let nonces = await api.nonces
        XCTAssertEqual(nonces, 0)
        XCTAssertNil(center.prompt)
    }

    func test_twoRequests_areShownOneAfterTheOther() async throws {
        try await giveDeviceAKey()
        let center = self.center!
        let first = Task { try await center.sign(self.request) }
        while center.prompt == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        let other = ApprovalRequest(kind: .account, subject: ["op": "link_device", "code": "BCDF2345"], headline: "Sign in a new device")
        let second = Task { try await center.sign(other) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(center.prompt?.request, request, "the second waits behind the first")
        center.confirm()
        _ = try await first.value
        while center.prompt?.request != other { try await Task.sleep(nanoseconds: 2_000_000) }
        center.confirm()
        let signedOrNil = try await second.value
        let approval = try XCTUnwrap(signedOrNil)
        XCTAssertEqual(try statement(approval)["subject"] as? [String: String], ["op": "link_device", "code": "BCDF2345"])
    }

    // MARK: Attach after signing in again

    func test_keyAttachedToNoDevice_isAttachedBeforeAnythingElseIsSigned() async throws {
        let stored = try await giveDeviceAKey(attachedTo: nil)
        await center.refresh()
        XCTAssertEqual(center.status, .needsAttach)
        let signedOrNil = try await sign(request)
        let approval = try XCTUnwrap(signedOrNil)
        let attached = await api.attached
        XCTAssertEqual(attached.count, 1)
        let attach = try statement(attached[0])
        XCTAssertEqual(attach["type"] as? String, "account")
        XCTAssertEqual(attach["subject"] as? [String: String], ["op": "attach_key", "key_id": stored.keyID])
        XCTAssertEqual(attach["nonce"] as? String, "nonce-1")
        // The request itself is signed after, with its own nonce.
        XCTAssertEqual(try statement(approval)["nonce"] as? String, "nonce-2")
        XCTAssertEqual(center.status, .ready)
    }

    func test_keyAttachedToAnOldSignIn_needsAttach() async throws {
        try await giveDeviceAKey(attachedTo: 1)
        await center.refresh()
        XCTAssertEqual(center.status, .needsAttach)
        try await center.attach()
        XCTAssertEqual(center.status, .ready)
        let attached = await api.attached
        XCTAssertEqual(attached.count, 1)
    }

    // MARK: Enrolment

    func test_enrolWithPasswordAndCode_createsAndKeepsTheKey() async throws {
        await center.refresh()
        XCTAssertEqual(center.status, .noAccountKey)
        try await center.enrol(password: "pw", code: "123456")
        XCTAssertEqual(center.status, .ready)
        let stored = try XCTUnwrap(store.load())
        let keys = await api.keys
        XCTAssertEqual(keys.map(\.keyID), [stored.keyID])
        XCTAssertEqual(keys.first?.name, "alice's iPhone")
        XCTAssertEqual(center.deviceFingerprint, ApprovalKeyEncoding.fingerprint(keyID: stored.keyID))
    }

    func test_enrolRefused_keepsNoKey() async throws {
        await api.set(enrolError: ApprovalKeyError.badCode)
        do {
            try await center.enrol(password: "pw", code: "000000")
            XCTFail("expected bad code")
        } catch {
            XCTAssertEqual(error as? ApprovalKeyError, .badCode)
        }
        // The key made for the attempt is kept for the next try (the same
        // key, so a retry after a typo does not litter the account), but
        // the account has none and nothing can be signed.
        XCTAssertEqual(center.status, .noAccountKey)
        let keys = await api.keys
        XCTAssertTrue(keys.isEmpty)
    }

    func test_askAnotherDevice_thenApprovedThere() async throws {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "alice's Mac", deviceID: 8)])
        await center.refresh()
        XCTAssertEqual(center.status, .noDeviceKey)
        try await center.requestFromAnotherDevice()
        XCTAssertEqual(center.status, .waitingForApproval)
        let stored = try XCTUnwrap(store.load())
        XCTAssertEqual(center.deviceFingerprint, ApprovalKeyEncoding.fingerprint(keyID: stored.keyID))
        // The other device approves: the key appears on the account.
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "alice's Mac", deviceID: 8),
                             ApprovalKeyDTO(keyID: stored.keyID, name: "alice's iPhone", deviceID: 3, enrolledVia: .device)])
        await api.set(requests: [])
        await center.refresh()
        XCTAssertEqual(center.status, .ready)
    }

    func test_approveAnotherDevicesRequest_signsEnrolKeyForItsFingerprint() async throws {
        try await giveDeviceAKey()
        let newKeyID = String(repeating: "cd", count: 32)
        await api.set(requests: [ApprovalKeyRequestDTO(id: "kr_1", keyID: newKeyID, name: "alice's Mac")])
        await center.refresh()
        let request = try XCTUnwrap(center.state?.requests.first)
        let center = self.center!
        let task = Task { try await center.approve(request) }
        while center.prompt == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(center.prompt?.request.subject, ["op": "enrol_key", "key_id": newKeyID])
        center.confirm()
        try await task.value
        let approved = await api.approvedRequests
        XCTAssertEqual(approved.first?.id, "kr_1")
        XCTAssertEqual(try statement(approved[0].approval)["subject"] as? [String: String],
                       ["op": "enrol_key", "key_id": newKeyID])
    }

    func test_removeThisDevicesKey_signsRevoke_andDeletesIt() async throws {
        let stored = try await giveDeviceAKey()
        await center.refresh()
        let key = try XCTUnwrap(center.state?.keys.first)
        let center = self.center!
        let task = Task { try await center.revoke(key) }
        while center.prompt == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        center.confirm()
        try await task.value
        let revoked = await api.revoked
        XCTAssertEqual(revoked.first?.keyID, stored.keyID)
        XCTAssertNotNil(revoked.first?.approval)
        XCTAssertNil(store.load(), "a removed key can never be used again, so it is deleted")
        XCTAssertEqual(center.status, .noAccountKey)
    }

    func test_removeWithPasswordAndCode_whenThisDeviceCannotSign() async throws {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "lost phone", deviceID: 8)])
        await center.refresh()
        try await center.revoke(XCTUnwrap(center.state?.keys.first), password: "pw", code: "123456")
        let revoked = await api.revoked
        XCTAssertEqual(revoked.first?.keyID, "aa")
        XCTAssertNil(revoked.first?.approval)
    }

    // MARK: Status

    func test_status_disabledAndUnavailable() async throws {
        await api.set(enabled: false)
        await center.refresh()
        XCTAssertEqual(center.status, .disabled)

        await api.set(enabled: true)
        center = makeCenter(provider: SoftwareKeyProvider(availability: .unavailable(advice: "Do it on your iPhone.")))
        await center.refresh()
        XCTAssertEqual(center.status, .unavailable(advice: "Do it on your iPhone."))
    }

    func test_sign_onADeviceThatCannotHoldAKey_whenTheAccountHasOne() async {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "alice's iPhone", deviceID: 8)])
        center = makeCenter(provider: SoftwareKeyProvider(availability: .unavailable(advice: "Do it on your iPhone.")))
        do {
            _ = try await center.sign(request)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .noKeyOnThisDevice)
        }
    }
}

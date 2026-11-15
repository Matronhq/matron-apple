import XCTest
import MatronAuth
import MatronStorage
@testable import MatronJournal
@testable import MatronViewModels

@MainActor
final class ApprovalKeysScreenModelTests: XCTestCase {
    private var api: FakeApprovalKeysAPI!
    private var store: ApprovalKeyStore!

    override func setUp() async throws {
        api = FakeApprovalKeysAPI()
        store = ApprovalKeyStore(store: MemorySessionStore(), host: "journal.example", user: "alice")
    }

    private func model(provider: any ApprovalKeyProviding = SoftwareKeyProvider()) async -> ApprovalKeysScreenModel {
        let center = ApprovalCenter(api: api, keys: provider, store: store, user: "alice", deviceID: 3,
                                    deviceName: "alice's iPhone")
        let model = ApprovalKeysScreenModel(center: center, locale: Locale(identifier: "en_GB"),
                                            timeZone: TimeZone(identifier: "UTC")!)
        await model.load()
        return model
    }

    @discardableResult
    private func giveDeviceAKey(attachedTo deviceID: Int64? = 3) async throws -> StoredApprovalKey {
        let stored = try SoftwareKeyProvider().create()
        try store.save(stored)
        await api.set(keys: [ApprovalKeyDTO(keyID: stored.keyID, name: "alice's iPhone", deviceID: deviceID,
                                            createdAt: Date(timeIntervalSince1970: 1_794_000_000))])
        return stored
    }

    func test_noKeyYet_offersSetUpOnly() async {
        let model = await model()
        XCTAssertEqual(model.statusTitle, "No approval key yet")
        XCTAssertTrue(model.canSetUp)
        XCTAssertFalse(model.canAskAnotherDevice, "no device has a key to approve with")
        XCTAssertFalse(model.canAttach)
        XCTAssertNil(model.fingerprint)
        XCTAssertEqual(model.summary, "Not set up")
        XCTAssertFalse(model.needsAttention)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func test_accountHasAKeyElsewhere_offersBothWays_andNeedsAttention() async {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "alice's Mac", deviceID: 8, enrolledVia: .device)])
        let model = await model()
        XCTAssertEqual(model.statusTitle, "This device has no key")
        XCTAssertTrue(model.canSetUp)
        XCTAssertTrue(model.canAskAnotherDevice)
        XCTAssertTrue(model.needsAttention)
        XCTAssertEqual(model.rows.first?.detail.hasPrefix("Approved from another device · "), true)
    }

    func test_ready_showsTheFingerprint_andMarksThisDevicesRow() async throws {
        let stored = try await giveDeviceAKey()
        let model = await model()
        XCTAssertEqual(model.statusTitle, "This device can approve")
        XCTAssertEqual(model.fingerprint, ApprovalKeyEncoding.fingerprint(keyID: stored.keyID))
        XCTAssertFalse(model.canSetUp)
        XCTAssertFalse(model.needsAttention)
        XCTAssertEqual(model.rows.map(\.isThisDevice), [true])
        XCTAssertEqual(model.rows.first?.detail, "Added with password and code · 6 Nov 2026")
        XCTAssertNil(model.rows.first?.state)
    }

    func test_needsAttach_offersReattach_andSaysTheKeyIsUnattached() async throws {
        try await giveDeviceAKey(attachedTo: nil)
        let model = await model()
        XCTAssertTrue(model.canAttach)
        XCTAssertTrue(model.needsAttention)
        XCTAssertEqual(model.summary, "Needs re-attaching")
        XCTAssertEqual(model.rows.first?.state, "Not attached to a signed-in device")
        await model.attach()
        XCTAssertEqual(model.center.status, .ready)
        XCTAssertNil(model.error)
    }

    func test_requests_leaveOutThisDevicesOwn_andAskForAttentionWhenItCanApprove() async throws {
        let stored = try await giveDeviceAKey()
        await api.set(requests: [ApprovalKeyRequestDTO(id: "kr_1", keyID: "cd", name: "alice's Mac"),
                                 ApprovalKeyRequestDTO(id: "kr_2", keyID: stored.keyID, name: "alice's iPhone")])
        let model = await model()
        XCTAssertEqual(model.requests.map(\.id), ["kr_1"])
        XCTAssertTrue(model.needsAttention)
    }

    func test_setUpForm_enrols_clearsWhatWasTyped_andCloses() async {
        let model = await model()
        model.beginSetUp()
        XCTAssertEqual(model.form, .setUp)
        XCTAssertFalse(model.canSubmitForm)
        model.password = "pw"
        model.code = "123456"
        XCTAssertTrue(model.canSubmitForm)
        let done = await model.submitForm()
        XCTAssertTrue(done)
        XCTAssertNil(model.form)
        XCTAssertEqual(model.password, "")
        XCTAssertEqual(model.code, "")
        XCTAssertEqual(model.center.status, .ready)
    }

    func test_setUpForm_refusal_staysOpen_withTheReason_andNothingTypedKept() async {
        await api.set(enrolError: ApprovalKeyError.totpRequired)
        let model = await model()
        model.beginSetUp()
        model.password = "pw"
        model.code = "abcd-efgh"
        let done = await model.submitForm()
        XCTAssertFalse(done)
        XCTAssertEqual(model.form, .setUp)
        XCTAssertEqual(model.error, ApprovalKeyError.totpRequired.errorDescription)
        XCTAssertEqual(model.password, "")
    }

    func test_remove_withNoKeyToSignWith_asksForPasswordAndCode() async throws {
        await api.set(keys: [ApprovalKeyDTO(keyID: "aa", name: "lost phone", deviceID: 8)])
        let model = await model()
        let key = try XCTUnwrap(model.rows.first?.key)
        await model.remove(key)
        XCTAssertEqual(model.form, .remove(key))
        model.password = "pw"
        model.code = "123456"
        let done = await model.submitForm()
        XCTAssertTrue(done)
        let revoked = await api.revoked
        XCTAssertEqual(revoked.first?.keyID, "aa")
        XCTAssertNil(revoked.first?.approval)
        XCTAssertEqual(model.rows.first?.state?.hasPrefix("Removed "), true)
    }

    func test_unavailableDevice_saysWhatToDo() async {
        let model = await model(provider: SoftwareKeyProvider(availability: .unavailable(advice: "Do it on your iPhone.")))
        XCTAssertEqual(model.statusTitle, "This device can't hold a key")
        XCTAssertEqual(model.statusDetail, "Do it on your iPhone.")
        XCTAssertFalse(model.canSetUp)
    }
}

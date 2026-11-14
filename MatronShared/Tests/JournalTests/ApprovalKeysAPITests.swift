import XCTest
import MatronModels
@testable import MatronJournal

final class ApprovalKeysAPITests: XCTestCase {
    private func api(status: Int = 200, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://journal.example")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func sentBody() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any])
    }

    private func path() -> String { ItemsStubURLProtocol.lastRequest?.url?.path ?? "" }

    private let approval = SignedApproval(statement: "{\"v\":1}", signature: "sig")

    // MARK: Reading keys

    func test_approvalKeys_decodesKeysAndRequests() async throws {
        let state = try await api(body: [
            "enabled": true, "journal": "journal.example",
            "keys": [
                ["key_id": ApprovalVectors.keyID, "public_key": ApprovalVectors.publicKey, "alg": "ES256", "name": "alice's iPhone",
                 "device_id": 3, "enrolled_via": "password", "created_at": 1_790_000_000_000, "revoked_at": NSNull()],
                ["key_id": String(repeating: "ab", count: 32), "public_key": "x", "alg": "ES256", "name": "old Mac",
                 "device_id": NSNull(), "enrolled_via": "device", "created_at": 1_780_000_000_000, "revoked_at": 1_785_000_000_000],
            ],
            "requests": [["id": "kr_1", "key_id": String(repeating: "cd", count: 32), "name": "alice's Mac", "created_at": 1_790_000_000_500]],
        ]).approvalKeys()
        XCTAssertTrue(state.enabled)
        XCTAssertEqual(state.journal, "journal.example")
        XCTAssertEqual(state.keys.count, 2)
        XCTAssertEqual(state.keys[0].fingerprint, "7734f909")
        XCTAssertEqual(state.keys[0].deviceID, 3)
        XCTAssertEqual(state.keys[0].enrolledVia, .password)
        XCTAssertTrue(state.keys[0].isLive)
        XCTAssertNil(state.keys[1].deviceID)
        XCTAssertFalse(state.keys[1].isLive)
        XCTAssertTrue(state.hasActiveKey)
        XCTAssertEqual(state.requests.first?.fingerprint, "cdcdcdcd")
        XCTAssertEqual(path(), "/approval-keys")
    }

    func test_approvalKeys_disabledJournal() async throws {
        let state = try await api(body: ["enabled": false, "journal": NSNull(), "keys": [], "requests": []]).approvalKeys()
        XCTAssertFalse(state.enabled)
        XCTAssertNil(state.journal)
        XCTAssertFalse(state.hasActiveKey)
    }

    func test_nonce() async throws {
        let nonce = try await api(body: ["nonce": ApprovalVectors.nonce, "expires_at": 1_790_000_300_000]).approvalNonce()
        XCTAssertEqual(nonce.nonce, ApprovalVectors.nonce)
        XCTAssertEqual(nonce.expiresAt, Date(timeIntervalSince1970: 1_790_000_300))
        XCTAssertEqual(path(), "/approvals/nonce")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
    }

    // MARK: Enrolment and its refusals

    func test_enrol_sendsThePublicKeyNamePasswordAndCode() async throws {
        let key = try await api(body: ["key": ["key_id": ApprovalVectors.keyID, "name": "alice's iPhone", "device_id": 3,
                                               "enrolled_via": "password", "created_at": 1]])
            .enrolApprovalKey(publicKey: ApprovalVectors.publicKey, name: "alice's iPhone", password: "pw", code: "123456")
        XCTAssertEqual(key.keyID, ApprovalVectors.keyID)
        let body = try sentBody()
        XCTAssertEqual(body["public_key"] as? String, ApprovalVectors.publicKey)
        XCTAssertEqual(body["name"] as? String, "alice's iPhone")
        XCTAssertEqual(body["password"] as? String, "pw")
        XCTAssertEqual(body["code"] as? String, "123456")
        XCTAssertEqual(path(), "/approval-keys")
    }

    func test_enrol_refusalsAreNamed() async {
        let cases: [(Int, [String: Any], ApprovalKeyError)] = [
            (409, ["error": "approval_keys_disabled"], .disabled),
            (400, ["error": "bad_public_key"], .badPublicKey),
            (429, ["error": "enrolment_locked", "retry_at": 1_790_000_000_000],
             .enrolmentLocked(retryAt: Date(timeIntervalSince1970: 1_790_000_000))),
            (409, ["error": "two_factor_required"], .twoFactorRequired),
            (400, ["error": "totp_required"], .totpRequired),
            (401, ["error": "bad_password"], .badPassword),
            (403, ["error": "bad_code"], .badCode),
            (409, ["error": "key_exists"], .keyExists),
            (503, ["error": "two_factor_unavailable"], .twoFactorUnavailable),
        ]
        for (status, body, expected) in cases {
            do {
                _ = try await api(status: status, body: body)
                    .enrolApprovalKey(publicKey: "k", name: "n", password: "p", code: "c")
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error as? ApprovalKeyError, expected)
            }
        }
    }

    func test_requestApproveRevokeAttach_paths() async throws {
        let keyJSON: [String: Any] = ["key": ["key_id": ApprovalVectors.keyID, "name": "n", "created_at": 1]]
        let id = try await api(status: 201, body: ["id": "kr_abc"]).requestApprovalKey(publicKey: "k", name: "n")
        XCTAssertEqual(id, "kr_abc")
        XCTAssertEqual(path(), "/approval-keys/requests")

        _ = try await api(body: keyJSON).approveApprovalKeyRequest(id: "kr_abc", approval: approval)
        XCTAssertEqual(path(), "/approval-keys/requests/kr_abc/approve")
        XCTAssertEqual((try sentBody()["approval"] as? [String: String]), ["statement": "{\"v\":1}", "signature": "sig"])

        try await api(body: keyJSON).revokeApprovalKey(keyID: ApprovalVectors.keyID, approval: approval)
        XCTAssertEqual(path(), "/approval-keys/\(ApprovalVectors.keyID)/revoke")
        XCTAssertNotNil(try sentBody()["approval"])

        try await api(body: keyJSON).revokeApprovalKey(keyID: ApprovalVectors.keyID, password: "pw", code: "123456")
        XCTAssertNil(try sentBody()["approval"])
        XCTAssertEqual(try sentBody()["password"] as? String, "pw")

        _ = try await api(body: keyJSON).attachApprovalKey(approval: approval)
        XCTAssertEqual(path(), "/approval-keys/attach")
    }

    // MARK: Refusals on every route

    func test_errors_approvalRequiredInvalidAndLocked() async {
        func error(_ status: Int, _ body: [String: Any]) async -> JournalAPIError? {
            do { _ = try await api(status: status, body: body).devices(); return nil } catch { return error as? JournalAPIError }
        }
        let required = await error(403, ["error": "approval_required"])
        XCTAssertEqual(required, .approvalRequired)
        let invalid = await error(400, ["error": "approval_invalid", "reason": "mismatch"])
        XCTAssertEqual(invalid, .approvalInvalid(reason: "mismatch"))
        let locked = await error(423, ["error": "account_locked"])
        XCTAssertEqual(locked, .accountLocked)
        XCTAssertEqual(locked?.errorDescription, "This account is locked.")
        let lockedBare = await error(423, [:])
        XCTAssertEqual(lockedBare, .accountLocked)
        // An ordinary 403 is still the plain refusal.
        let forbidden = await error(403, ["error": "forbidden"])
        XCTAssertEqual(forbidden, .forbidden)
    }

    func test_everyRefusalReasonHasItsOwnSentence() {
        let reasons = ["mismatch", "nonce", "revoked_key", "wrong_device", "unknown_key", "signature"]
        let texts = Set(reasons.map(JournalAPIError.approvalInvalidText))
        XCTAssertEqual(texts.count, reasons.count)
        XCTAssertEqual(JournalAPIError.approvalInvalidText("signature"), JournalAPIError.approvalInvalidText("bad_statement"))
        XCTAssertTrue(JournalAPIError.approvalInvalidText("zzz").contains("zzz"))
    }

    // MARK: Signed taps and account actions

    func test_tapItem_carriesTheApprovalAndTheIdempotencyKey() async throws {
        let item: [String: Any] = ["id": "it_1", "num": 7, "kind": "question", "state": "open", "title": "Deploy box-a",
                                   "origin_convo_id": "c1", "created_at": 1, "updated_at": 2]
        let comment: [String: Any] = ["id": "cm_1", "item_id": "it_1", "author": "user", "kind": "comment", "body": "Approve",
                                      "created_at": 3, "action": "Approve",
                                      "approval": ["statement": ApprovalVectors.itemTap.statement, "signature": ApprovalVectors.itemTap.signature]]
        let result = try await api(status: 201, body: ["item": item, "comment": comment])
            .tapItem(id: "it_1", action: "Approve", replyTo: "cm_9", approval: approval, idempotencyKey: "idem-1")
        let body = try sentBody()
        XCTAssertEqual(body["action"] as? String, "Approve")
        XCTAssertEqual(body["reply_to"] as? String, "cm_9")
        XCTAssertEqual(body["approval"] as? [String: String], ["statement": "{\"v\":1}", "signature": "sig"])
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "idem-1")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Matron-Item-Inline"), "attachments")
        XCTAssertEqual(result.comment?.signedKeyID, ApprovalVectors.keyID)
    }

    func test_accountAction_isSignedWhenTheSignerAnswers() async throws {
        let api = api(body: ["signed_out": 0])
        let seen = Seen()
        let approval = self.approval
        await api.setApprovalSigner { request in
            await seen.record(request)
            return approval
        }
        _ = try await api.changePassword(oldPassword: "old", newPassword: "new-password", signOutOthers: false)
        let body = try sentBody()
        XCTAssertEqual(body["old_password"] as? String, "old")
        XCTAssertNotNil(body["approval"])
        let request = await seen.requests.first
        XCTAssertEqual(request?.kind, .account)
        XCTAssertEqual(request?.subject, ["op": "change_password"])
        XCTAssertEqual(request?.headline, "Change password")
    }

    func test_accountAction_goesUnsignedWhenTheAccountHasNoKey() async throws {
        let api = api(body: ["ok": true])
        await api.setApprovalSigner { _ in nil }
        try await api.linkApprove(code: "BCDF2345")
        XCTAssertNil(try sentBody()["approval"])
        XCTAssertEqual(try sentBody()["link_code"] as? String, "BCDF2345")
    }

    func test_accountAction_isNotSentWhenTheUserCancels() async {
        let api = api(body: ["ok": true])
        await api.setApprovalSigner { _ in throw ApprovalKeyFailure.cancelled }
        do {
            try await api.linkApprove(code: "BCDF2345")
            XCTFail("expected cancel")
        } catch {
            XCTAssertEqual(error as? ApprovalKeyFailure, .cancelled)
        }
        XCTAssertNil(ItemsStubURLProtocol.lastRequest, "nothing is sent for an approval the user backed out of")
    }

    func test_accountAction_subjects() async throws {
        let seen = Seen()
        let approval = self.approval
        func signing(_ api: JournalAPI) async -> JournalAPI {
            await api.setApprovalSigner { request in await seen.record(request); return approval }
            return api
        }
        try await signing(api(body: ["ok": true])).pairApprove(code: "ABCD-1234", agentName: "box-a", tagChar: "a")
        _ = try await signing(api(body: ["convo_id": NSNull()])).setCoordinator(nil)
        _ = try await signing(api(body: ["consent": false])).setCoordinatorConsent(false)
        try await signing(api(body: ["ok": true])).revokeOtherDevice(id: 12, name: "alice's Mac")
        try await signing(api(body: ["ok": true, "device_id": 5, "protected": true])).setDeviceProtected(id: 5, name: "box-a", on: true)
        try await signing(api(body: ["ok": true])).disableTwoFactor(password: "pw", code: "123456")
        let subjects = await seen.requests.map(\.subject)
        XCTAssertEqual(subjects, [
            ["op": "pair_bridge", "code": "ABCD-1234", "name": "box-a"],
            ["op": "set_coordinator", "convo": ""],
            ["op": "set_consent", "which": "spawns", "on": "false"],
            ["op": "revoke_device", "device": "12"],
            ["op": "protect_device", "device": "5", "on": "true"],
            ["op": "two_factor", "action": "disable"],
        ])
    }

    func test_consentAnswers_carryAnApprovalOnlyOnApprove() async throws {
        try await api(body: ["ok": true]).answerAgentSpawn(requestID: "sp_1", decision: .approve, approval: approval)
        XCTAssertNotNil(try sentBody()["approval"])
        try await api(body: ["ok": true]).answerAgentSpawn(requestID: "sp_1", decision: .deny, approval: approval)
        XCTAssertNil(try sentBody()["approval"])
        XCTAssertEqual(try sentBody().keys.sorted(), ["decision", "request_id"])
        _ = try await api(body: ["delivered": true])
            .answerAgentChat(roomID: "r1", targetDeviceID: 4, decision: .approve, approval: approval)
        XCTAssertNotNil(try sentBody()["approval"])
    }

    // MARK: Step-up on items, comments and devices

    func test_itemAndComment_decodeStepUpAndSubject() throws {
        let item = try XCTUnwrap(TrackerItem(json: [
            "id": "it_1", "num": 7, "kind": "question", "state": "open", "title": "Deploy box-a", "origin_convo_id": "c1",
            "created_at": 1, "updated_at": 2, "step_up": true, "subject": ["op": "deploy", "target": "production"],
        ]))
        XCTAssertTrue(item.stepUp)
        XCTAssertEqual(item.subject, ["op": "deploy", "target": "production"])
        let plain = try XCTUnwrap(TrackerItem(json: [
            "id": "it_2", "num": 8, "kind": "question", "state": "open", "title": "t", "origin_convo_id": "c1",
            "created_at": 1, "updated_at": 2, "step_up": false, "subject": NSNull(),
        ]))
        XCTAssertFalse(plain.stepUp)
        XCTAssertNil(plain.subject)
        let comment = try XCTUnwrap(TrackerComment(json: [
            "id": "cm_1", "item_id": "it_1", "author": "agent", "kind": "comment", "body": "Also restart the service?",
            "created_at": 3, "actions": ["Yes", "No"], "step_up": true, "subject": ["box": "box-a"], "approval": NSNull(),
        ]))
        XCTAssertTrue(comment.stepUp)
        XCTAssertEqual(comment.subject, ["box": "box-a"])
        XCTAssertNil(comment.signedKeyID)
    }

    func test_store_keepsStepUpAndSubject() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        // Whole seconds: the store keeps milliseconds.
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let item = TrackerItem(id: "it_1", num: 7, kind: .question, title: "Deploy box-a", originConvoID: "c1",
                               createdAt: at, updatedAt: at, actions: ["Approve"], stepUp: true, subject: ["box": "box-a"])
        let comment = TrackerComment(id: "cm_1", itemID: "it_1", author: .agent, body: "Also restart?", createdAt: at, actions: ["Yes"],
                                     stepUp: true, subject: ["svc": "web"], signedKeyID: nil)
        XCTAssertEqual(ItemRecord(item).item, item)
        XCTAssertEqual(ItemCommentRecord(comment).comment, comment)
        try store.upsertItems([item])
        let read = try XCTUnwrap(store.item(id: "it_1"))
        XCTAssertTrue(read.stepUp)
        XCTAssertEqual(read.subject, ["box": "box-a"])
    }

    func test_devices_decodeProtectedLockedAndIdleExpired() async throws {
        let devices = try await api(body: ["devices": [
            ["device_id": 5, "kind": "agent", "name": "box-a", "protected": true,
             "locked": ["on": false, "until": 1_790_000_600_000, "lockdown_until": NSNull()], "idle_expired": false],
            ["device_id": 6, "kind": "agent", "name": "box-b", "protected": false, "locked": ["on": true, "until": NSNull()]],
            ["device_id": 7, "kind": "client", "name": "old phone", "locked": NSNull(), "idle_expired": true],
        ]]).devices()
        XCTAssertTrue(devices[0].isProtected)
        XCTAssertEqual(devices[0].locked?.until, Date(timeIntervalSince1970: 1_790_000_600))
        XCTAssertTrue(devices[0].locked!.isUnlocked(at: Date(timeIntervalSince1970: 1_790_000_000)))
        XCTAssertFalse(devices[0].locked!.isUnlocked(at: Date(timeIntervalSince1970: 1_790_000_700)))
        XCTAssertNotNil(devices[1].locked)
        XCTAssertNil(devices[1].locked?.until)
        XCTAssertFalse(devices[1].isProtected)
        XCTAssertNil(devices[2].locked)
        XCTAssertTrue(devices[2].idleExpired)
    }
}

private actor Seen {
    var requests: [ApprovalRequest] = []
    func record(_ request: ApprovalRequest) { requests.append(request) }
}

import CryptoKit
import XCTest
import MatronAuth
import MatronJournal
import MatronModels
import MatronStorage
import MatronViewModels

/// Approval keys against the real journal (`JournalServerHarness`, with
/// its public URL set so the feature is on): enrolment with the password
/// and a code, a signed tap on a step-up item checked by the journal and
/// then by its reference verifier, a second device approved by the first,
/// a signed account action, re-attaching after signing in again, and
/// removal. The device keys are software keys: the flows are the app's
/// own, only the Secure Enclave is stood in for.
///
/// Needs a journal checkout that has approval keys (`MATRON_JOURNAL_PATH`);
/// against one that predates them the tests skip.
@MainActor
final class ApprovalKeysServerTests: XCTestCase {
    private let password = "correct horse battery"

    // MARK: Fixtures

    private final class MemoryStore: SessionStore, @unchecked Sendable {
        private var values: [String: String] = [:]
        private let lock = NSLock()
        func set(_ value: String, forKey key: String) throws { lock.withLock { values[key] = value } }
        func get(key: String) throws -> String? { lock.withLock { values[key] } }
        func delete(key: String) throws { lock.withLock { values[key] = nil } }
    }

    /// One signed-in app: its API client, its approval centre and its
    /// device id.
    private struct Device {
        let api: JournalAPI
        let center: ApprovalCenter
        let deviceID: Int64
    }

    /// A code generator for the account's authenticator. The journal takes
    /// each time step once, and accepts one step either side of now, so
    /// codes are handed out for strictly increasing steps, starting one
    /// step back; when the next would be more than one step ahead of the
    /// clock, it waits for the clock.
    private final class Authenticator {
        private let key: Data
        private var lastStep: Int64
        init(secret: String) {
            key = Self.base32(secret)
            lastStep = Int64(Date().timeIntervalSince1970 / 30) - 2
        }

        func nextCode() async throws -> String {
            let step = lastStep + 1
            while Int64(Date().timeIntervalSince1970 / 30) < step - 1 {
                try await Task.sleep(for: .milliseconds(500))
            }
            lastStep = step
            return Self.code(key: key, step: step)
        }

        static func code(key: Data, step: Int64) -> String {
            var counter = UInt64(step).bigEndian
            let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(bytes: &counter, count: 8), using: SymmetricKey(data: key))
            let bytes = Array(mac)
            let offset = Int(bytes[19] & 0x0f)
            let value = (UInt32(bytes[offset] & 0x7f) << 24) | (UInt32(bytes[offset + 1]) << 16)
                | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
            return String(format: "%06d", value % 1_000_000)
        }

        static func base32(_ text: String) -> Data {
            let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
            var bits = 0, value = 0
            var out = Data()
            for ch in text.uppercased() where ch != "=" && ch != " " {
                guard let index = alphabet.firstIndex(of: ch) else { continue }
                value = (value << 5) | index
                bits += 5
                if bits >= 8 {
                    out.append(UInt8((value >> (bits - 8)) & 0xff))
                    bits -= 8
                }
            }
            return out
        }
    }

    private func startHarness() async throws -> JournalServerHarness {
        let harness = try await JournalServerHarness.start(
            users: [.init("alice", password: password)],
            agents: [.init(user: "alice", name: "box-a")],
            publicURL: true)
        // A journal from before approval keys answers 404 here.
        var request = URLRequest(url: harness.baseURL.appendingPathComponent("approval-keys"))
        request.setValue("Bearer \(harness.agentTokens["box-a"] ?? "")", forHTTPHeaderField: "Authorization")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 404 {
                throw XCTSkip("this journal checkout has no approval keys; point MATRON_JOURNAL_PATH at one that does")
            }
        } catch {
            // The caller's own `defer` is not in place yet.
            harness.stop()
            throw error
        }
        return harness
    }

    /// Signs in (with a code once two-factor is on) and builds the app's
    /// approval centre over `store`, the device's key store.
    private func signIn(_ harness: JournalServerHarness, name: String, store: ApprovalKeyStore,
                        authenticator: Authenticator?) async throws -> Device {
        let auth = JournalAuthService(sessionStore: InMemorySessionStore())
        let session: UserSession
        do {
            session = try await auth.loginPassword(homeserverURL: harness.baseURL, username: "alice", password: password,
                                                   initialDeviceDisplayName: name)
        } catch AuthError.twoFactorRequired(let challenge) {
            let code = try await XCTUnwrap(authenticator).nextCode()
            session = try await auth.verifyTwoFactor(challenge, code: code).session
        }
        let api = JournalAPI(serverURL: harness.baseURL, token: session.accessToken)
        let deviceID = try XCTUnwrap(Int64(session.deviceID))
        let center = ApprovalCenter(api: api, keys: SoftwareKeyProvider(), store: store, user: "alice",
                                    deviceID: deviceID, deviceName: name)
        await api.setApprovalSigner(center.signer)
        return Device(api: api, center: center, deviceID: deviceID)
    }

    private func keyStore(_ harness: JournalServerHarness) -> ApprovalKeyStore {
        ApprovalKeyStore(store: MemoryStore(), host: harness.baseURL.host ?? "", user: "alice")
    }

    /// Runs `work` while standing in for the user at the confirm sheet:
    /// each request that comes up is recorded and confirmed.
    private func confirming<T>(_ centers: [ApprovalCenter], _ work: () async throws -> T) async rethrows -> (T, [ApprovalRequest]) {
        let seen = SeenRequests()
        let watcher = Task { @MainActor in
            var confirmed: Set<UUID> = []
            while !Task.isCancelled {
                for center in centers {
                    guard let prompt = center.prompt, !center.isSigning else { continue }
                    if !confirmed.contains(prompt.id) {
                        confirmed.insert(prompt.id)
                        seen.requests.append(prompt.request)
                        center.confirm()
                    } else if let error = center.promptError {
                        // A failed try leaves the sheet up for another:
                        // report it and back out, or the test would wait
                        // for ever.
                        XCTFail("signing failed: \(error)")
                        center.cancel()
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { watcher.cancel() }
        let result = try await work()
        return (result, seen.requests)
    }

    @MainActor private final class SeenRequests { var requests: [ApprovalRequest] = [] }

    private func turnOnTwoFactor(_ api: JournalAPI) async throws -> Authenticator {
        let setup = try await api.beginTwoFactorSetup(password: password, code: nil)
        let authenticator = Authenticator(secret: setup.secret)
        _ = try await api.enableTwoFactor(code: try await authenticator.nextCode(), signOutOthers: false)
        return authenticator
    }

    private func post(_ harness: JournalServerHarness, _ path: String, token: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: harness.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertTrue((200...201).contains(status), "\(path) answered \(status): \(String(decoding: data, as: UTF8.self))")
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func rawItem(_ harness: JournalServerHarness, token: String, id: String) async throws -> [String: Any] {
        var request = URLRequest(url: harness.baseURL.appendingPathComponent("items/\(id)"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("attachments", forHTTPHeaderField: "X-Matron-Item-Inline")
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private final class NoSync: ItemsSyncing, @unchecked Sendable {
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async {}
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }

    // MARK: Tests

    func testEnrolThenASignedTapPassesTheJournalAndTheReferenceVerifier() async throws {
        let harness = try await startHarness()
        defer { harness.stop() }
        let agentToken = try XCTUnwrap(harness.agentTokens["box-a"])
        let phone = try await signIn(harness, name: "alice's iPhone", store: keyStore(harness), authenticator: nil)

        // Before a key: nothing is signed, and the account says so.
        await phone.center.refresh()
        XCTAssertEqual(phone.center.status, .noAccountKey)
        XCTAssertEqual(phone.center.state?.journal, "127.0.0.1:\(harness.baseURL.port ?? 0)")

        // Two-factor must be on to set a key up with the password.
        do {
            try await phone.center.enrol(password: password, code: "000000")
            XCTFail("expected two_factor_required")
        } catch {
            XCTAssertEqual(error as? ApprovalKeyError, .twoFactorRequired)
        }
        let authenticator = try await turnOnTwoFactor(phone.api)
        try await phone.center.enrol(password: password, code: try await authenticator.nextCode())
        XCTAssertEqual(phone.center.status, .ready)
        let keyID = try XCTUnwrap(phone.center.deviceKeyID)
        let listed = try XCTUnwrap(phone.center.state?.key(keyID))
        XCTAssertEqual(listed.deviceID, phone.deviceID)
        XCTAssertEqual(listed.enrolledVia, .password)
        XCTAssertEqual(listed.name, "alice's iPhone")

        // An agent files a step-up question.
        let agent = try await FakeAgent.connect(baseURL: harness.baseURL, token: agentToken)
        defer { agent.close() }
        try await agent.convoUpsert(id: "c1", title: "Deploys", sessionState: "running")
        let subject = ["op": "deploy", "repo": "example/app", "target": "production"]
        let created = try await post(harness, "items", token: agentToken, [
            "kind": "question", "title": "Deploy box-a", "body": "Roll out the new build?", "convo_id": "c1",
            "actions": ["Approve", "Decline"], "step_up": true, "subject": subject,
        ])
        XCTAssertNil(created["step_up_ignored"], "the account has a key, so the mark is kept")
        let itemID = try XCTUnwrap((created["item"] as? [String: Any])?["id"] as? String)
        let (item, _) = try await phone.api.item(id: itemID)
        XCTAssertTrue(item.stepUp)
        XCTAssertEqual(item.subject, subject)

        // Unsigned, the journal refuses it.
        do {
            _ = try await phone.api.commentItem(id: itemID, body: "Approve", attachments: [], action: "Approve",
                                                replyTo: nil, idempotencyKey: UUID().uuidString)
            XCTFail("expected approval_required")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .approvalRequired)
        }

        // Signed, through the app's own path, it counts.
        let (outcome, shown) = await confirming([phone.center]) {
            await StepUpTap.send(item: item, comment: nil, label: "Approve", api: phone.api, sync: NoSync(),
                                 signer: phone.center.signer)
        }
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(shown.first?.subject, subject, "the sheet showed the subject as signed")
        XCTAssertEqual(shown.first?.button, "Approve")
        let (answered, comments) = try await phone.api.item(id: itemID)
        XCTAssertEqual(answered.chosenAction, "Approve")
        XCTAssertEqual(comments.last?.signedKeyID, keyID)

        // A box checks the stored approval itself, against a pinned key.
        let raw = try await rawItem(harness, token: agentToken, id: itemID)
        let tap = try XCTUnwrap((raw["comments"] as? [[String: Any]])?.last { $0["action"] as? String == "Approve" })
        let approval = try XCTUnwrap(tap["approval"] as? [String: String])
        let pinned = [["key_id": keyID, "public_key": listed.publicKey, "name": "alice's iPhone"]]
        let expect: [String: Any] = [
            "journal": "127.0.0.1:\(harness.baseURL.port ?? 0)", "user": "alice", "type": "item_tap", "subject": subject,
            "item_num": item.num, "action": "Approve", "reply_to": NSNull(),
            "prompt_digest": PromptDigest.item(title: "Deploy box-a", body: "Roll out the new build?"), "item_id": itemID,
        ]
        let verdict = try harness.verifyApproval(approval, keys: pinned, expect: expect)
        XCTAssertEqual(verdict.status, 0, verdict.output)
        // The same approval for another button is refused.
        var other = expect
        other["action"] = "Decline"
        XCTAssertEqual(try harness.verifyApproval(approval, keys: pinned, expect: other).status, 1)

        // A follow-up question marked step-up, answered the same way.
        let followUp = try await post(harness, "items/\(itemID)/comments", token: agentToken, [
            "body": "Also restart the service?", "actions": ["Yes", "No"], "step_up": true, "subject": ["svc": "web"],
        ])
        let commentID = try XCTUnwrap((followUp["comment"] as? [String: Any])?["id"] as? String)
        let (reread, thread) = try await phone.api.item(id: itemID)
        let asking = try XCTUnwrap(thread.first { $0.id == commentID })
        XCTAssertTrue(asking.stepUp)
        let (second, shownAgain) = await confirming([phone.center]) {
            await StepUpTap.send(item: reread, comment: asking, label: "Yes", api: phone.api, sync: NoSync(),
                                 signer: phone.center.signer)
        }
        XCTAssertEqual(second, .sent)
        XCTAssertEqual(shownAgain.first?.subject, ["svc": "web"])
        let (_, after) = try await phone.api.item(id: itemID)
        XCTAssertEqual(after.first { $0.id == commentID }?.chosenAction, "Yes")
    }

    func testConsentAndAccountStatementsPassTheReferenceVerifier() async throws {
        let harness = try await startHarness()
        defer { harness.stop() }
        let key = SoftwareApprovalKey()
        let pinned = [["key_id": key.keyID, "public_key": key.publicKeyBase64URL, "name": "test"]]
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let cases: [(ApprovalStatement.Kind, ApprovalSubject)] = [
            (.consent, ApprovalSubjects.spawn(ask: "sp_1", box: "box-a", workdir: "/home/alice/project", task: "Run the tests — “all” of them ✓")),
            (.account, ApprovalSubjects.unlockBox(box: "box-a", minutes: 30)),
            (.account, ApprovalSubjects.clearLockdown(box: "box-a")),
            (.account, ApprovalSubjects.linkDevice(code: "BCDF2345")),
        ]
        for (kind, subject) in cases {
            let statement = ApprovalStatement(kind: kind, journal: "journal.example", user: "alice", keyID: key.keyID,
                                              nonce: "q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq8k", signedAt: now, subject: subject)
            let approval = try await statement.signed(by: key, reason: "test")
            let verdict = try harness.verifyApproval(
                approval.json as? [String: String] ?? [:], keys: pinned,
                expect: ["journal": "journal.example", "user": "alice", "type": kind.wireType, "subject": subject])
            XCTAssertEqual(verdict.status, 0, "\(subject): \(verdict.output)")
        }
    }

    func testSecondDeviceAccountActionReattachAndRemoval() async throws {
        let harness = try await startHarness()
        defer { harness.stop() }
        let phoneKeys = keyStore(harness)
        let phone = try await signIn(harness, name: "alice's iPhone", store: phoneKeys, authenticator: nil)
        let authenticator = try await turnOnTwoFactor(phone.api)
        try await phone.center.enrol(password: password, code: try await authenticator.nextCode())
        let phoneKeyID = try XCTUnwrap(phone.center.deviceKeyID)

        // A Mac signs in and asks the phone to add its key.
        let mac = try await signIn(harness, name: "alice's Mac", store: keyStore(harness), authenticator: authenticator)
        await mac.center.refresh()
        XCTAssertEqual(mac.center.status, .noDeviceKey)
        // With a key on the account, an account change from the Mac needs
        // a signature it cannot give yet.
        do {
            _ = try await mac.api.setCoordinatorConsent(false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .noKeyOnThisDevice)
        }
        try await mac.center.requestFromAnotherDevice()
        XCTAssertEqual(mac.center.status, .waitingForApproval)
        let macKeyID = try XCTUnwrap(mac.center.deviceKeyID)

        await phone.center.refresh()
        let request = try XCTUnwrap(phone.center.state?.requests.first)
        XCTAssertEqual(request.keyID, macKeyID, "the phone shows the fingerprint the Mac shows")
        let (_, shown) = try await confirming([phone.center]) { try await phone.center.approve(request) }
        XCTAssertEqual(shown.first?.subject, ["op": "enrol_key", "key_id": macKeyID])
        await mac.center.refresh()
        XCTAssertEqual(mac.center.status, .ready)
        XCTAssertEqual(mac.center.state?.key(macKeyID)?.enrolledVia, .device)

        // The Mac can now sign an account action.
        let (stored, account) = try await confirming([mac.center]) { try await mac.api.setCoordinatorConsent(false) }
        XCTAssertEqual(stored, false)
        XCTAssertEqual(account.first?.subject, ["op": "set_consent", "which": "spawns", "on": "false"])

        // The phone signs in again: a new device row, the same key. It
        // must re-attach before it signs anything else.
        let phoneAgain = try await signIn(harness, name: "alice's iPhone", store: phoneKeys, authenticator: authenticator)
        await phoneAgain.center.refresh()
        XCTAssertEqual(phoneAgain.center.status, .needsAttach)
        XCTAssertNotEqual(phoneAgain.deviceID, phone.deviceID)
        let (again, _) = try await confirming([phoneAgain.center]) { try await phoneAgain.api.setCoordinatorConsent(true) }
        XCTAssertEqual(again, true)
        XCTAssertEqual(phoneAgain.center.status, .ready)
        XCTAssertEqual(phoneAgain.center.state?.key(phoneKeyID)?.deviceID, phoneAgain.deviceID)

        // The Mac removes the phone's key; the phone learns it is gone.
        await mac.center.refresh()
        let phoneKey = try XCTUnwrap(mac.center.state?.key(phoneKeyID))
        _ = try await confirming([mac.center]) { try await mac.center.revoke(phoneKey) }
        await phoneAgain.center.refresh()
        XCTAssertEqual(phoneAgain.center.status, .revoked)
        do {
            _ = try await phoneAgain.api.setCoordinatorConsent(false)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? ApprovalError, .keyRevoked)
        }
    }
}

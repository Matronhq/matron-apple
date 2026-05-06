import XCTest
import Foundation
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync
import MatronVerification

/// SDK-level integration test for the verify-with-other-device flow.
///
/// Drives the same code path that the in-app "Verify with another device"
/// button does — `MacPostLoginVerificationView` →
/// `service.startSAS(withUser: session.userID, deviceID: nil)` →
/// `requestDeviceVerification()` — without the SwiftUI layer in between.
/// Coordinates with `partner.mjs wait-verify` running as a second device of
/// `@matron`: the partner stands as the trust anchor, this test is the new
/// device verifying against it.
///
/// Why SDK-level instead of XCUITest: every bug burned through Phase 3
/// Waves 1–7 was at the SDK layer (delegate wiring, role-asymmetric
/// `startSasVerification` calls, lazy controller build), and Mac SwiftUI
/// `TextField` paste-after-Tab is its own quagmire. Driving the SDK
/// directly is faster to iterate and isolates the layer the bugs live in.
///
/// Skips cleanly unless the harness is up. To run end-to-end:
///
///     tests/integration/run-harness.sh verify-sdk-against-partner.sh
///
/// To run manually with a long-running harness:
///
///     tests/integration/run-harness.sh                    # leaves harness up
///     export MATRON_HOMESERVER=http://localhost:6167
///     export MATRON_USER=matron MATRON_PW=matron-test-pw
///     export MATRON_PARTNER_STORE=tests/integration/artifacts/<ts>/partner-store.json
///     export MATRON_PARTNER_NODE_SCRIPT=tests/integration/partner/partner.mjs
///     xcodebuild test -scheme MatronMac -destination 'platform=macOS' \
///         -only-testing:MatronIntegrationTests/VerificationFlowIntegrationTests \
///         CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
///         AD_HOC_CODE_SIGNING_ALLOWED=YES
final class VerificationFlowIntegrationTests: XCTestCase {

    private var basePath: URL!
    private var partnerProcess: Process?
    private var partnerLines: PartnerLineSource?
    private var partnerStdoutBuffer = StdoutLineBuffer()
    private var partnerStdoutLogPath: String?
    private var partnerStderrLogPath: String?
    private var partnerStdoutLogHandle: FileHandle?
    private var partnerStderrLogHandle: FileHandle?
    private var partnerCommandLine: String?
    private var syncService: SyncServiceLive?

    override func setUpWithError() throws {
        try super.setUpWithError()
        basePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-int-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        if let s = syncService { await s.stop() }
        syncService = nil
        if let p = partnerProcess, p.isRunning { p.terminate() }
        partnerProcess = nil
        await partnerLines?.close()
        partnerLines = nil
        try? partnerStdoutLogHandle?.close()
        try? partnerStderrLogHandle?.close()
        partnerStdoutLogHandle = nil
        partnerStderrLogHandle = nil
        try? FileManager.default.removeItem(at: basePath)
        try await super.tearDown()
    }

    func testVerifyWithOtherDeviceAgainstPartner() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        try await assertHomeserverReachable(homeserverURL)
        guard let nodeScript = env["MATRON_PARTNER_NODE_SCRIPT"],
              FileManager.default.fileExists(atPath: nodeScript) else {
            throw XCTSkip("MATRON_PARTNER_NODE_SCRIPT not set or file missing")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"

        // ORDER MATTERS: partner must bootstrap cross-signing on the
        // server BEFORE matron-app signs in. Otherwise matron's first
        // /keys/query lands an empty user-identity into its local
        // crypto store, and `requestDeviceVerification` later fails
        // with `Failed retrieving user identity` even though the
        // listener fires `.unverified`. (Earlier runs that signed in
        // first happened to work by accident — the second sync round
        // sometimes picked up partner's bootstrap before the test
        // called startSAS, but it's a race.)

        // 1. Spawn partner.mjs in `bootstrap-and-wait` mode — bootstraps
        //    cross-signing AND waits for verification in one
        //    long-running process so all post-bootstrap in-memory
        //    crypto state stays loaded (mirrors
        //    claude-matrix-bridge/add-bot.mjs).
        try spawnPartnerBootstrapAndWait(
            scriptPath: nodeScript,
            homeserver: homeserverString,
            user: username,
            password: password,
            timeout: 120
        )
        try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        try await waitForPartnerEvent(.event("ready"), timeout: 5)

        // 2. Sign in fresh (mirrors the Mac app's first-launch path).
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-test-integration"
        )

        // 3. Bring sync online — verification needs the user identity
        //    loaded (`installVerificationStateListener` only builds the
        //    controller once the SDK fires `!= .unknown`).
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        // 4. Drive startSAS through to .verified.
        //
        //    Wait for matron's local crypto store to have a complete
        //    user identity before calling startSAS. The
        //    `verificationStateListener` firing `.unverified` is
        //    necessary but NOT sufficient — partner's freshly-uploaded
        //    cross-signing identity needs another /keys/query round
        //    before `getSessionVerificationController` can resolve it.
        //    Without this wait we get
        //    `ClientError.Generic("Failed retrieving user identity")`.
        //    Retry verification.start() (which blocks on awaitController)
        //    until it succeeds, then proceed.
        let verification = VerificationServiceLive(provider: provider, session: session)
        var startReady = false
        var lastStartError: Error?
        for _ in 0..<60 {
            do {
                try await verification.start()
                startReady = true
                break
            } catch {
                lastStartError = error
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        XCTAssertTrue(
            startReady,
            "verification.start() never succeeded within 30s — last error: \(String(describing: lastStartError))"
        )
        let stream = verification.startSAS(withUser: session.userID, deviceID: nil)
        try await driveSAS(stream: stream, requestID: session.userID, verification: verification)

        // 5. Confirm the partner side wrapped up cleanly.
        try await waitForPartnerEvent(.ok(true), timeout: 30)

        // 6. Persistence check: the SDK's `verificationState()` should
        //    flip to verified now that SAS completed and partner has
        //    cross-signed matron's device. Catches a class of bugs
        //    where the AsyncStream yields .verified but the
        //    cross-signature never lands on this side — the spec §7.5
        //    posture is "nothing auto-trusted", so a stream-only
        //    success without persistence would be a security bug.
        //    `verifyDone` in the verify gate also reads this state.
        //
        //    Race note: matron must download partner's freshly-uploaded
        //    cross-signature via /keys/query before its local
        //    verificationState transitions. Allow generous polling.
        var persisted = false
        var lastState = "(uncalled)"
        for _ in 0..<150 {
            let state = (try? await verification.isThisDeviceVerified()) ?? nil
            lastState = state.map { $0 ? "true" : "false" } ?? "nil"
            if state == true {
                persisted = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(
            persisted,
            "SAS yielded .verified but isThisDeviceVerified() never returned true within 15s (last value: \(lastState))"
        )
    }

    /// Matron-as-RESPONDER. Inverse of the verify test: partner is the
    /// initiator (sends `m.key.verification.request` to matron). matron
    /// receives via `incomingRequests()`, calls `acceptIncoming(requestID:)`,
    /// drives SAS to `.verified`. Exercises the `acceptIncoming` +
    /// `routeAcceptedVerificationRequest(role: .responder)` code paths
    /// that the requester test doesn't touch — these are the production
    /// paths the per-bot trust banner (Phase 5) will use.
    ///
    /// **Currently skipped** — matron receives the request
    /// (`routeIncomingRequest` fires) but the flow stalls before SAS
    /// advances. matrix-rust-sdk's `didAcceptVerificationRequest`
    /// delegate may only fire on the requester side, so matron's
    /// `routeAcceptedVerificationRequest`-driven `startSasVerification`
    /// call never happens here. The matron-vs-matron live-validated case
    /// might rely on the Element-X "user taps Start button" UX explicitly
    /// firing the SAS-start; needs more investigation. Set
    /// `MATRON_RUN_INCOMING_VERIFY_TEST=1` to actually try.
    func testAcceptIncomingVerificationRequestFromPartner() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MATRON_RUN_INCOMING_VERIFY_TEST"] == "1" else {
            throw XCTSkip("incoming-verify SDK test stalls past routeIncomingRequest — see test docstring; set MATRON_RUN_INCOMING_VERIFY_TEST=1 to attempt")
        }
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        try await assertHomeserverReachable(homeserverURL)
        guard let nodeScript = env["MATRON_PARTNER_NODE_SCRIPT"],
              FileManager.default.fileExists(atPath: nodeScript) else {
            throw XCTSkip("MATRON_PARTNER_NODE_SCRIPT not set or file missing")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"

        // 1. Spawn partner in initiate-mode (bootstraps then sends
        //    verification.request once matron's device is visible).
        try spawnPartnerCommand(
            scriptPath: nodeScript,
            command: "bootstrap-and-initiate-verify",
            extraArgs: [
                "--homeserver", homeserverString,
                "--user", username,
                "--password", password,
                "--device-name", "matron-test-partner",
                "--timeout", "120",
            ]
        )
        try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        try await waitForPartnerEvent(.event("ready"), timeout: 5)

        // 2. matron signs in fresh AFTER partner bootstrap, so matron's
        //    first /keys/query lands a complete cross-signing identity.
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-test-integration"
        )

        // 3. Sync online + verification controller ready.
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()
        let verification = VerificationServiceLive(provider: provider, session: session)
        var startReady = false
        for _ in 0..<60 {
            if (try? await verification.start()) != nil { startReady = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(startReady, "verification.start() never succeeded — user identity didn't load within 30s")

        // 4. Set up the incomingRequests stream BEFORE partner sends
        //    .request. Otherwise routeIncomingRequest may fire and
        //    drop the yield (the `setIncomingContinuation` call is
        //    async, so there's a window after `incomingRequests()`
        //    returns but before the continuation is actually
        //    registered on the FlowStore actor).
        let incomingStream = verification.incomingRequests()
        var iterator = incomingStream.makeAsyncIterator()
        // Give the FlowStore's setIncomingContinuation Task a beat
        // to actually register before we move on.
        try await Task.sleep(nanoseconds: 100_000_000)

        // 5. Wait for partner to discover matron's device + send request.
        //    Partner emits `other_device_seen` then `verify_requested`
        //    once it dispatches the to-device .request event.
        try await waitForPartnerEvent(.event("other_device_seen"), timeout: 60)
        try await waitForPartnerEvent(.event("verify_requested"), timeout: 30)

        // 6. matron receives the incoming request via incomingRequests()
        //    and accepts it.
        let incoming = try await withThrowingTaskGroup(of: VerificationRequestSummary?.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw IntegrationError.timeout("matron never observed an incoming verification request within 30s")
            }
            group.addTask { await iterator.next() }
            let result = try await group.next()
            group.cancelAll()
            return result ?? nil
        }
        guard let incoming else {
            XCTFail("incomingRequests() yielded nil")
            return
        }
        XCTAssertEqual(incoming.otherUserID, session.userID)

        // 6. Drive acceptIncoming to .verified.
        let stream = verification.acceptIncoming(requestID: incoming.id)
        try await driveSAS(stream: stream, requestID: incoming.id, verification: verification)

        // 7. Confirm partner side wrapped up (cross_signed + ok:true).
        try await waitForPartnerEvent(.ok(true), timeout: 30)

        // 8. Persistence: matron's verificationState should flip
        //    .verified once partner's cross-signature lands locally.
        var verifiedAfter = false
        for _ in 0..<60 {
            if try await verification.isThisDeviceVerified() == true { verifiedAfter = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(verifiedAfter, "isThisDeviceVerified() never returned true within 30s of incoming-verification completion")
    }

    /// Recovery-key restore path. Mirrors the verify-gate's "Use recovery
    /// key" branch: matron-app signs in fresh, doesn't go through SAS,
    /// and instead restores cross-signing access via a previously-issued
    /// recovery key. After restore, `isThisDeviceVerified()` should
    /// return true (cross-signing private keys are now available locally
    /// and matron's device gets self-signed).
    ///
    /// Re-validates the Wave 7 fix that switched the SDK call from
    /// `recover` to `recoverAndFixBackup` — the docstring says the
    /// former left historical messages undecryptable, but it hasn't been
    /// automated. This test exercises the API path; full historical-
    /// decryption coverage would need a follow-up that also asserts on
    /// post-restore message decryption.
    func testRecoveryKeyRestoreVerifiesThisDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        try await assertHomeserverReachable(homeserverURL)
        guard let nodeScript = env["MATRON_PARTNER_NODE_SCRIPT"],
              FileManager.default.fileExists(atPath: nodeScript) else {
            throw XCTSkip("MATRON_PARTNER_NODE_SCRIPT not set or file missing")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"

        // 1. Partner bootstraps + emits recovery_key on `bootstrapped`.
        try spawnPartnerBootstrapAndWait(
            scriptPath: nodeScript,
            homeserver: homeserverString,
            user: username,
            password: password,
            timeout: 120
        )
        let bootstrapped = try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        guard let recoveryKey = bootstrapped["recovery_key"] as? String else {
            XCTFail("partner did not include recovery_key in bootstrapped payload: \(bootstrapped)")
            return
        }
        try await waitForPartnerEvent(.event("ready"), timeout: 5)

        // 2. matron signs in fresh.
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-test-recovery"
        )

        // 3. Sync ready (so the SDK's identity machinery is wired).
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        // 4. Wait for matron's user identity to be loaded
        //    (`verification.start()` blocks on `awaitController` which
        //    waits for the listener to fire `!= .unknown`). Same race
        //    we saw in the verify test.
        let verification = VerificationServiceLive(provider: provider, session: session)
        var startReady = false
        for _ in 0..<60 {
            if (try? await verification.start()) != nil {
                startReady = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(startReady, "verification.start() never succeeded — user identity didn't load within 30s")

        // 5. Restore via the recovery key. RecoveryKeyManager uses
        //    plain-Keychain (non-iCloud) here so the test bundle
        //    doesn't need iCloud-Keychain entitlements.
        let keychain = KeychainStore(service: "chat.matron.test-recovery.\(UUID().uuidString.prefix(8))")
        let manager = RecoveryKeyManager(provider: provider, session: session, keychain: keychain)
        try await manager.restore(usingKey: recoveryKey)

        // 6. After restore, the device should be considered verified.
        //    Wave 7 used `recoverAndFixBackup` so cross-signing private
        //    keys land locally and matron self-signs its device.
        var verifiedAfterRestore = false
        for _ in 0..<60 {  // up to 30s
            if try await verification.isThisDeviceVerified() == true {
                verifiedAfterRestore = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(
            verifiedAfterRestore,
            "isThisDeviceVerified() never returned true within 30s of recovery-key restore — Wave 7 recoverAndFixBackup may have regressed"
        )
    }

    /// Reproduces (or rules out) the "empty chat list after fresh sign-in"
    /// regression noted in HANDOVER.md. Partner creates an encrypted room
    /// on the server BEFORE matron-app signs in; matron-app then signs in
    /// and asks for `chatSummaries()`, which should yield a snapshot
    /// containing the room. If the snapshot is empty, the bug reproduces
    /// at the SDK / sliding-sync layer; if it lands fine, the bug is in
    /// the UI binding above ChatService.
    func testChatListShowsRoomCreatedByOtherDevice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let homeserverString = env["MATRON_HOMESERVER"] ?? env["HOMESERVER"] else {
            throw XCTSkip("MATRON_HOMESERVER not set; run via tests/integration/run-harness.sh")
        }
        guard let homeserverURL = URL(string: homeserverString) else {
            throw XCTSkip("MATRON_HOMESERVER not a valid URL: \(homeserverString)")
        }
        try await assertHomeserverReachable(homeserverURL)
        guard let nodeScript = env["MATRON_PARTNER_NODE_SCRIPT"],
              FileManager.default.fileExists(atPath: nodeScript) else {
            throw XCTSkip("MATRON_PARTNER_NODE_SCRIPT not set or file missing")
        }
        let username = env["MATRON_USER"] ?? "matron"
        let password = env["MATRON_PW"] ?? "matron-test-pw"
        let roomName = "Integration test room \(UUID().uuidString.prefix(8))"

        // 1. Partner: bootstrap + create room BEFORE matron signs in.
        try spawnPartnerBootstrapAndWait(
            scriptPath: nodeScript,
            homeserver: homeserverString,
            user: username,
            password: password,
            timeout: 120,
            createRoomNamed: roomName
        )
        try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        try await waitForPartnerEvent(.event("room_created"), timeout: 30)

        // 2. matron-app fresh sign-in — same first-launch path the verify
        //    test exercises.
        let storeDir = basePath.appendingPathComponent("session-store")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let sdkStore = basePath.appendingPathComponent("sdk-store")
        let auth = AuthServiceLive(
            sessionStore: FileSessionStore(directory: storeDir),
            basePath: sdkStore
        )
        let session = try await auth.loginPassword(
            homeserverURL: homeserverURL,
            username: username,
            password: password,
            initialDeviceDisplayName: "matron-test-integration"
        )

        // 3. Sync online — chatSummaries() blocks on this.
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        // 4. Pull a chat-list snapshot. ChatServiceLive.chatSummaries()
        //    is single-shot per call — yields one snapshot then finishes.
        //    Sliding sync may not have downloaded the room on the first
        //    call (it's eventually consistent), so retry with backoff
        //    before declaring the bug reproduced.
        let chatService = ChatServiceLive(provider: provider, session: session, sync: sync)
        var lastSnapshot: [ChatSummary] = []
        var observed = false
        for _ in 0..<30 {  // up to 30 * 1s = 30s
            for try await snapshot in chatService.chatSummaries() {
                lastSnapshot = snapshot
                if !snapshot.isEmpty { observed = true }
                break  // single-shot stream — first value is the snapshot
            }
            if observed { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(
            observed,
            "chatSummaries() never yielded a non-empty snapshot within 30s of sync ready — empty-chats regression reproduces at the SDK layer (lastSnapshot: \(lastSnapshot))"
        )
    }

    // MARK: - Helpers

    private func assertHomeserverReachable(_ homeserverURL: URL) async throws {
        let url = homeserverURL.appendingPathComponent("_matrix/client/versions")
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            throw XCTSkip("homeserver \(homeserverURL) not reachable: \(error.localizedDescription)")
        }
    }

    private func driveSAS(
        stream: AsyncStream<SasFlowState>,
        requestID: String,
        verification: VerificationServiceLive
    ) async throws {
        let timeoutSeconds: TimeInterval = 60
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw IntegrationError.timeout(
                    "SAS flow did not reach .verified within \(Int(timeoutSeconds))s"
                )
            }
            group.addTask {
                var didConfirm = false  // matrix-rust-sdk fires didReceiveVerificationData
                                        // twice for the same SAS round; calling
                                        // approveVerification twice sends two .mac
                                        // events and trips the partner's MAC check.
                                        // Confirm exactly once per flow.
                for await state in stream {
                    switch state {
                    case .idle, .requested, .awaitingConfirmation:
                        continue
                    case .readyForEmoji(let emojis):
                        XCTAssertFalse(emojis.isEmpty, "SAS emoji list was empty")
                        if !didConfirm {
                            didConfirm = true
                            try await verification.confirmEmojiMatch(requestID: requestID)
                        }
                    case .verified:
                        XCTAssertTrue(
                            didConfirm,
                            ".verified arrived without ever emitting .readyForEmoji"
                        )
                        return
                    case .cancelled(let reason):
                        throw IntegrationError.sasCancelled(reason)
                    }
                }
                throw IntegrationError.streamEndedEarly
            }
            try await group.next()
            group.cancelAll()
        }
    }

    /// Spawn a partner.mjs subprocess running the named command with the
    /// given extra arguments. Common plumbing (node-bin resolution,
    /// stdout/stderr capture to /tmp + line-source actor wiring) is
    /// shared with `spawnPartnerBootstrapAndWait`.
    private func spawnPartnerCommand(
        scriptPath: String,
        command: String,
        extraArgs: [String]
    ) throws {
        try spawnPartnerProcess(scriptPath: scriptPath, args: [command] + extraArgs)
    }

    private func spawnPartnerBootstrapAndWait(
        scriptPath: String,
        homeserver: String,
        user: String,
        password: String,
        timeout: Int,
        createRoomNamed: String? = nil
    ) throws {
        var args = ["bootstrap-and-wait",
                    "--homeserver", homeserver,
                    "--user", user,
                    "--password", password,
                    "--device-name", "matron-test-partner",
                    "--timeout", String(timeout)]
        if let createRoomNamed { args.append(contentsOf: ["--create-room", createRoomNamed]) }
        try spawnPartnerProcess(scriptPath: scriptPath, args: args)
    }

    /// Resolve `node` explicitly. xctest runners don't inherit nvm /
    /// Homebrew PATH, so `/usr/bin/env node` resolves to nothing and the
    /// subprocess exits 127 before producing any output. The harness
    /// exports `MATRON_NODE_BIN=$(command -v node)` so we get the same
    /// node the developer's shell uses; fall back to common locations
    /// for ad-hoc runs without the harness env.
    private static func resolveNodeBin() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let supplied = env["MATRON_NODE_BIN"], FileManager.default.isExecutableFile(atPath: supplied) {
            return supplied
        }
        let fallbacks = [
            "/opt/homebrew/bin/node",        // Apple Silicon Homebrew
            "/usr/local/bin/node",            // Intel Homebrew
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin/node",
            "/usr/bin/node",                  // system (rare)
        ]
        guard let resolved = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw IntegrationError.timeout(
                "could not resolve `node` binary. Set MATRON_NODE_BIN env var (the harness does this)."
            )
        }
        return resolved
    }

    /// Inner spawn: takes the partner command + args (script path is
    /// prepended automatically). Wires pipes, /tmp logging, and the
    /// line-source actor.
    private func spawnPartnerProcess(scriptPath: String, args: [String]) throws {
        let process = Process()
        process.launchPath = try Self.resolveNodeBin()
        process.arguments = [scriptPath] + args

        // Mirror everything to /tmp so a failed run leaves a readable trace
        // we can inspect from the harness without parsing the xcresult.
        partnerStdoutLogPath = "/tmp/matron-partner-stdout.log"
        partnerStderrLogPath = "/tmp/matron-partner-stderr.log"
        let stdoutFH = try makeLogFileHandle(at: partnerStdoutLogPath!)
        let stderrFH = try makeLogFileHandle(at: partnerStderrLogPath!)
        partnerStdoutLogHandle = stdoutFH
        partnerStderrLogHandle = stderrFH

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let lines = PartnerLineSource()
        partnerLines = lines
        let buffer = partnerStdoutBuffer

        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                Task { await lines.close() }
                handle.readabilityHandler = nil
                return
            }
            try? stdoutFH.write(contentsOf: data)
            let completedLines = buffer.append(data: data)
            if !completedLines.isEmpty {
                Task { await lines.push(lines: completedLines) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            try? stderrFH.write(contentsOf: data)
        }

        try process.run()
        partnerProcess = process
        partnerCommandLine = "\(process.launchPath ?? "<no launch path>") \((process.arguments ?? []).joined(separator: " "))"
    }

    private func makeLogFileHandle(at path: String) throws -> FileHandle {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: path) else {
            throw IntegrationError.partnerNotSpawned
        }
        return fh
    }

    /// Reads back the captured partner output for inclusion in a failure
    /// message. Best-effort — if the files don't exist (subprocess never
    /// started), returns empty strings.
    private func partnerOutputDump() -> String {
        let stdoutContents = partnerStdoutLogPath
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "<not captured>"
        let stderrContents = partnerStderrLogPath
            .flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "<not captured>"
        let exitInfo: String
        if let p = partnerProcess {
            if p.isRunning {
                exitInfo = "still running (pid \(p.processIdentifier))"
            } else {
                exitInfo = "terminationStatus=\(p.terminationStatus) reason=\(p.terminationReason.rawValue)"
            }
        } else {
            exitInfo = "<no process>"
        }
        return """
        partner cmd: \(partnerCommandLine ?? "<unset>")
        partner exit: \(exitInfo)
        --- partner stdout (\(partnerStdoutLogPath ?? "<no path>")):
        \(stdoutContents)
        --- partner stderr (\(partnerStderrLogPath ?? "<no path>")):
        \(stderrContents)
        """
    }

    private enum PartnerExpectation {
        case event(String)            // matches `obj["event"] == name`
        case ok(Bool)                 // matches `obj["ok"] == bool`
    }

    @discardableResult
    private func waitForPartnerEvent(
        _ expectation: PartnerExpectation,
        timeout: TimeInterval
    ) async throws -> [String: Any] {
        guard let lines = partnerLines else {
            throw IntegrationError.partnerNotSpawned
        }
        do {
            return try await withThrowingTaskGroup(of: [String: Any].self) { group in
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw IntegrationError.timeout(
                        "partner did not emit \(expectation) within \(Int(timeout))s"
                    )
                }
                group.addTask {
                    while let line = await lines.next() {
                        guard let data = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continue
                        }
                        switch expectation {
                        case .event(let name):
                            if let event = obj["event"] as? String, event == name { return obj }
                        case .ok(let expected):
                            if let actual = obj["ok"] as? Bool, actual == expected { return obj }
                        }
                    }
                    throw IntegrationError.partnerExited
                }
                let payload = try await group.next() ?? [:]
                group.cancelAll()
                return payload
            }
        } catch {
            // Give the readability handlers a beat to drain the final
            // bytes from the dying subprocess before we snapshot.
            if let p = partnerProcess { p.waitUntilExit() }
            try? await Task.sleep(nanoseconds: 200_000_000)
            try? partnerStdoutLogHandle?.synchronize()
            try? partnerStderrLogHandle?.synchronize()
            XCTFail("\(error). Partner subprocess context:\n\(partnerOutputDump())")
            throw error
        }
    }

    enum IntegrationError: Error, CustomStringConvertible {
        case timeout(String)
        case sasCancelled(String)
        case streamEndedEarly
        case partnerExited
        case partnerNotSpawned
        var description: String {
            switch self {
            case .timeout(let m): return "timeout: \(m)"
            case .sasCancelled(let r): return "SAS cancelled: \(r)"
            case .streamEndedEarly: return "AsyncStream<SasFlowState> finished before .verified"
            case .partnerExited: return "partner subprocess exited before emitting expected event"
            case .partnerNotSpawned: return "partner subprocess was never spawned"
            }
        }
    }
}

// MARK: - Subprocess line plumbing

/// Single-consumer FIFO of completed stdout lines from the partner subprocess.
/// The pipe's `readabilityHandler` runs on a background queue and pushes
/// lines in; the test pulls via `next()` and may suspend if the queue is
/// empty. `close()` resolves any pending pull with `nil`.
private actor PartnerLineSource {
    private var pending: [String] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private var closed = false

    func push(lines: [String]) {
        pending.append(contentsOf: lines)
        drain()
    }

    func close() {
        closed = true
        drain()
    }

    func next() async -> String? {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        if closed { return nil }
        return await withCheckedContinuation { cont in
            waiter = cont
        }
    }

    private func drain() {
        if let cont = waiter, !pending.isEmpty {
            waiter = nil
            cont.resume(returning: pending.removeFirst())
            return
        }
        if closed, let cont = waiter {
            waiter = nil
            cont.resume(returning: nil)
        }
    }
}

/// Accumulates byte chunks from the subprocess pipe and splits them into
/// complete lines. The pipe handler can hand us partial lines mid-write —
/// JSON objects from `partner.mjs` are emitted one-per-`emit()` so each
/// completed line is a parseable JSON document.
///
/// A class (not actor) because the pipe `readabilityHandler` is synchronous;
/// access is single-threaded by the handler invariant. Locked anyway so a
/// hypothetical concurrent caller can't tear the buffer.
private final class StdoutLineBuffer: @unchecked Sendable {
    private var partial = ""
    private let lock = NSLock()

    func append(data: Data) -> [String] {
        guard let chunk = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        partial += chunk
        var completed: [String] = []
        while let newlineRange = partial.range(of: "\n") {
            let line = String(partial[..<newlineRange.lowerBound])
            partial.removeSubrange(..<newlineRange.upperBound)
            if !line.isEmpty { completed.append(line) }
        }
        return completed
    }
}

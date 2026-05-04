import XCTest
import Foundation
import MatronAuth
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

        // 1. Sign in fresh (mirrors the Mac app's first-launch path).
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

        // 2. Bring sync online — verification needs the user identity loaded
        //    (`installVerificationStateListener` only builds the controller
        //    once the SDK fires `!= .unknown`).
        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        // 3. Spawn partner.mjs in `bootstrap-and-wait` mode — this
        //    bootstraps cross-signing AND waits for verification in
        //    the same long-running process, so all post-bootstrap
        //    in-memory crypto state stays loaded for the verification
        //    (mirrors claude-matrix-bridge/add-bot.mjs's working
        //    pattern; the split bootstrap-anchor + wait-verify shape
        //    we tried before consistently failed MAC interop).
        try spawnPartnerBootstrapAndWait(
            scriptPath: nodeScript,
            homeserver: homeserverString,
            user: username,
            password: password,
            timeout: 120
        )
        // bootstrap completes first (~10s), then partner emits "ready"
        try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        try await waitForPartnerEvent(.event("ready"), timeout: 5)

        // 4. Drive startSAS through to .verified.
        let verification = VerificationServiceLive(provider: provider, session: session)
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
            let state = (try? await verification.isThisDeviceVerified()) ?? false
            lastState = state ? "true" : "false"
            if state {
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

    private func spawnPartnerBootstrapAndWait(
        scriptPath: String,
        homeserver: String,
        user: String,
        password: String,
        timeout: Int
    ) throws {
        let process = Process()
        // Resolve `node` explicitly. xctest runners don't inherit nvm /
        // Homebrew PATH, so `/usr/bin/env node` resolves to nothing and the
        // subprocess exits 127 before producing any output. The harness
        // exports `MATRON_NODE_BIN=$(command -v node)` so we get the same
        // node the developer's shell uses; fall back to common locations
        // for ad-hoc runs without the harness env.
        let env = ProcessInfo.processInfo.environment
        let nodeBin: String
        if let supplied = env["MATRON_NODE_BIN"], FileManager.default.isExecutableFile(atPath: supplied) {
            nodeBin = supplied
        } else {
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
            nodeBin = resolved
        }
        process.launchPath = nodeBin
        process.arguments = [scriptPath, "bootstrap-and-wait",
                             "--homeserver", homeserver,
                             "--user", user,
                             "--password", password,
                             "--device-name", "matron-test-partner",
                             "--timeout", String(timeout)]

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
        partnerCommandLine = "\(nodeBin) \((process.arguments ?? []).joined(separator: " "))"
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

    private func waitForPartnerEvent(
        _ expectation: PartnerExpectation,
        timeout: TimeInterval
    ) async throws {
        guard let lines = partnerLines else {
            throw IntegrationError.partnerNotSpawned
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
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
                            if let event = obj["event"] as? String, event == name { return }
                        case .ok(let expected):
                            if let actual = obj["ok"] as? Bool, actual == expected { return }
                        }
                    }
                    throw IntegrationError.partnerExited
                }
                try await group.next()
                group.cancelAll()
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

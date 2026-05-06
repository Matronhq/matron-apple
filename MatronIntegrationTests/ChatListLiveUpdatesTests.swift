import XCTest
import Foundation
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync

/// Phase 2.5 Task 5 Step 5 — integration test for live chat-list updates.
///
/// Drives the long-lived `ChatServiceLive.chatSummaries()` stream against a
/// real homeserver: matron-app signs in, opens a `chatSummaries()`
/// consumer, waits for an initial snapshot, then spawns `partner.mjs
/// bootstrap-and-wait --create-room` as a SECOND DEVICE of the same
/// `@matron3` user. The new room must surface in matron's existing stream
/// within 10s — proving that the `RoomListSubscription` + per-room state
/// fan-out delivers diffs without needing a refresh or sign-out.
///
/// Skips silently when `MATRON_HOMESERVER` is unset (mirrors the other
/// SDK scenarios). Run end-to-end via:
///
///     tests/integration/run-harness.sh chat-list-live-updates-sdk.sh
///
/// or as part of the batch:
///
///     node tests/integration/run-all-ui.mjs
final class ChatListLiveUpdatesTests: XCTestCase {

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
            .appendingPathComponent("matron-chat-live-\(UUID().uuidString)")
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

    /// Matron subscribes first, partner creates a room SECOND, the new
    /// room surfaces in matron's already-running stream within 10s.
    func testChatList_receivesNewRoomFromOtherDevice_within10s() async throws {
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
        let username = env["MATRON_USER"] ?? "matron3"
        let password = env["MATRON_PW"] ?? "matron3-test-pw"
        let roomName = "Live update room \(UUID().uuidString.prefix(8))"

        // 1. matron-app fresh sign-in, sync online, build ChatServiceLive,
        //    open a `chatSummaries()` consumer, wait for a first snapshot
        //    (may be empty — fresh user has zero rooms yet, that's fine).
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
            initialDeviceDisplayName: "matron-chat-live-test"
        )

        let provider = ClientProvider(basePath: sdkStore)
        let sync = SyncServiceLive(provider: provider, session: session)
        syncService = sync
        try await sync.start()
        try await sync.waitUntilReady()

        let chatService = ChatServiceLive(provider: provider, session: session, sync: sync)
        let snapshots = SnapshotCapture()
        let consumerTask = Task {
            do {
                for try await snapshot in chatService.chatSummaries() {
                    await snapshots.append(snapshot)
                }
            } catch {
                await snapshots.fail(error)
            }
        }
        defer { consumerTask.cancel() }

        // 2. Wait for the first yield so we know the broadcaster is wired
        //    and the live `RoomListSubscription` has emitted at least once
        //    (initial `.reset` arrives immediately on subscribe — Task 1
        //    spike confirmed this against tuwunel).
        try await waitForSnapshot(snapshots, predicate: { _ in true }, timeoutSeconds: 30,
                                  reason: "first snapshot from broadcaster (proves consumer is registered)")
        let baselineCount = await snapshots.count()

        // 3. Spawn partner as a SECOND DEVICE of the same @matron user.
        //    `bootstrap-and-wait --create-room` logs in, bootstraps SSSS +
        //    cross-signing, creates a fresh encrypted room, then idles.
        //    The room creation echoes back to matron-app via sliding-sync;
        //    the long-lived `RoomListSubscription` must surface it as a
        //    diff into the already-registered consumer.
        try spawnPartnerBootstrapAndWait(
            scriptPath: nodeScript,
            homeserver: homeserverString,
            user: username,
            password: password,
            timeout: 120,
            createRoomNamed: roomName
        )
        try await waitForPartnerEvent(.event("bootstrapped"), timeout: 60)
        let createdPayload = try await waitForPartnerEvent(.event("room_created"), timeout: 30)
        let createdRoomID = createdPayload["room_id"] as? String
        XCTAssertNotNil(createdRoomID, "partner did not include room_id in room_created payload: \(createdPayload)")

        // 4. Assert: the new room shows up in a snapshot AFTER the baseline
        //    yield, within 10s. Sliding sync usually pushes the diff in
        //    well under a second once partner returns from /createRoom.
        try await waitForSnapshot(
            snapshots,
            predicate: { snapshot in
                guard let id = createdRoomID else { return false }
                return snapshot.contains(where: { $0.id == id })
            },
            timeoutSeconds: 10,
            reason: "live yield containing partner-created room \(createdRoomID ?? "<nil>") after baseline (\(baselineCount) prior snapshots)"
        )
    }

    // MARK: - Helpers

    private func waitForSnapshot(
        _ capture: SnapshotCapture,
        predicate: @Sendable @escaping ([ChatSummary]) -> Bool,
        timeoutSeconds: TimeInterval,
        reason: String
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let err = await capture.error {
                XCTFail("chatSummaries() consumer threw before \(reason): \(err)")
                throw err
            }
            if await capture.contains(where: predicate) {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        let dump = await capture.dump()
        XCTFail("Timed out after \(Int(timeoutSeconds))s waiting for: \(reason). Captured snapshots: \(dump)")
        throw IntegrationError.timeout(reason)
    }

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

    /// Resolve `node` explicitly. xctest runners don't inherit nvm /
    /// Homebrew PATH; the harness exports `MATRON_NODE_BIN=$(command -v
    /// node)` so we get the same node the developer's shell uses; fall
    /// back to common locations for ad-hoc runs without the harness env.
    private static func resolveNodeBin() throws -> String {
        let env = ProcessInfo.processInfo.environment
        if let supplied = env["MATRON_NODE_BIN"], FileManager.default.isExecutableFile(atPath: supplied) {
            return supplied
        }
        let fallbacks = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(NSHomeDirectory())/.nvm/versions/node/current/bin/node",
            "/usr/bin/node",
        ]
        guard let resolved = fallbacks.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw IntegrationError.timeout(
                "could not resolve `node` binary. Set MATRON_NODE_BIN env var (the harness does this)."
            )
        }
        return resolved
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

    private func spawnPartnerProcess(scriptPath: String, args: [String]) throws {
        let process = Process()
        process.launchPath = try Self.resolveNodeBin()
        process.arguments = [scriptPath] + args

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
        case event(String)
        case ok(Bool)
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
        case partnerExited
        case partnerNotSpawned
        var description: String {
            switch self {
            case .timeout(let m): return "timeout: \(m)"
            case .partnerExited: return "partner subprocess exited before emitting expected event"
            case .partnerNotSpawned: return "partner subprocess was never spawned"
            }
        }
    }
}

// MARK: - Subprocess line plumbing
//
// `PartnerLineSource` and `StdoutLineBuffer` are also defined (file-private)
// in `VerificationFlowIntegrationTests.swift`. They're duplicated here on
// purpose: the verification suite's helpers are file-private and lifting
// them to internal-scope would couple two unrelated test classes through
// shared mutable plumbing. The buffer + queue are tiny.

/// Single-consumer FIFO of completed stdout lines from the partner subprocess.
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
/// complete JSON lines. partner.mjs emits one JSON object per `emit()` so
/// each completed line is a parseable document.
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

// MARK: - Snapshot capture

/// Actor-protected accumulator of every `[ChatSummary]` snapshot the
/// consumer task receives. Lets the test poll for predicate matches
/// (`new room appears`) without racing the producer task.
private actor SnapshotCapture {
    private(set) var snapshots: [[ChatSummary]] = []
    private(set) var error: Error?

    func append(_ snapshot: [ChatSummary]) {
        snapshots.append(snapshot)
    }

    func fail(_ error: Error) {
        self.error = error
    }

    func count() -> Int { snapshots.count }

    func contains(where predicate: ([ChatSummary]) -> Bool) -> Bool {
        snapshots.contains(where: predicate)
    }

    /// Compact summary for failure messages — the full snapshot list can
    /// be large, so emit count + the room IDs in the most recent yield.
    func dump() -> String {
        guard let last = snapshots.last else {
            return "(none)"
        }
        let ids = last.map(\.id)
        return "\(snapshots.count) snapshots; latest has \(last.count) rooms: \(ids)"
    }
}

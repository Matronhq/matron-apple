import Darwin
import Foundation
import MatronStorage
import XCTest

/// Boots a real `matron-journal` server (Node) as a subprocess for
/// integration tests, provisions users/agents via the admin CLI, and tears
/// everything down (process + temp DB directory) on `stop()`.
///
/// Server checkout location resolves via `MATRON_JOURNAL_PATH` first, then
/// falls back to `~/Dev/matron-journal` (an *absolute* expansion of the
/// home directory — never a `../` path relative to the app repo, which is
/// fragile under xcodebuild's working directory). Missing checkout/node/
/// node_modules throws `XCTSkip`; any other startup failure (server crashed,
/// never became ready) is a real error and must fail the test, not skip it.
final class JournalServerHarness {
    struct UserSpec {
        let name: String
        let password: String
        init(_ name: String, password: String) {
            self.name = name
            self.password = password
        }
    }

    struct AgentSpec {
        let user: String
        let name: String
        init(user: String, name: String) {
            self.user = user
            self.name = name
        }
    }

    enum HarnessError: Error, CustomStringConvertible {
        case adminCLIFailed(arguments: [String], output: String)
        case tokenNotFound(agent: String, output: String)
        case portProbeFailed(String)
        case serverDidNotBecomeReady(lastError: Error?, diagnostics: String)

        var description: String {
            switch self {
            case let .adminCLIFailed(arguments, output):
                return "matron-admin \(arguments.joined(separator: " ")) failed:\n\(output)"
            case let .tokenNotFound(agent, output):
                return "could not parse token for agent \(agent) from admin CLI output:\n\(output)"
            case let .portProbeFailed(reason):
                return "free-port probe failed: \(reason)"
            case let .serverDidNotBecomeReady(lastError, diagnostics):
                return "matron-journal server did not become ready (last error: \(String(describing: lastError))):\n\(diagnostics)"
            }
        }
    }

    let baseURL: URL
    private(set) var agentTokens: [String: String]
    private let process: Process
    private let tempDir: URL
    private let diagnostics: DiagnosticsBuffer
    private let serverPath: String
    private let dbPath: String
    private let nodePath: String

    private init(
        baseURL: URL, process: Process, tempDir: URL, dbPath: String,
        serverPath: String, nodePath: String, agentTokens: [String: String], diagnostics: DiagnosticsBuffer
    ) {
        self.baseURL = baseURL
        self.process = process
        self.tempDir = tempDir
        self.dbPath = dbPath
        self.serverPath = serverPath
        self.nodePath = nodePath
        self.agentTokens = agentTokens
        self.diagnostics = diagnostics
    }

    /// Locates the checkout + node, provisions `users`/`agents` via the
    /// admin CLI (BEFORE the server boots — avoids any doubt about the
    /// admin CLI and the running server touching the same SQLite file
    /// concurrently, even though WAL mode makes that safe), boots
    /// `node src/server.js` on a free port, and polls `GET /snapshot`
    /// (expects 401) until ready.
    static func start(
        users: [UserSpec] = [], agents: [AgentSpec] = []
    ) async throws -> JournalServerHarness {
        let serverPath = try requireServerRepo()
        let nodePath = try resolveNodePath()

        // tempDir is only created once the XCTSkip-worthy preconditions
        // above have already passed — a skip must never leave a directory
        // behind to clean up. Everything below this point runs under a
        // single cleanup `catch`: any throw (provisioning, port probe,
        // boot, readiness) terminates a booted server process (if any) and
        // removes tempDir before rethrowing, so a failed start() never
        // leaks a temp DB directory or a subprocess.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("matron-journal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dbPath = tempDir.appendingPathComponent("matron.sqlite").path

        var bootedProcess: Process?
        do {
            for user in users {
                _ = try runAdminCLI(nodePath: nodePath, serverPath: serverPath, dbPath: dbPath,
                                    arguments: ["user", "add", user.name, "--password", user.password])
            }
            var tokens: [String: String] = [:]
            for agent in agents {
                let output = try runAdminCLI(nodePath: nodePath, serverPath: serverPath, dbPath: dbPath,
                                             arguments: ["agent", "add", agent.user, agent.name])
                tokens[agent.name] = try parseAgentToken(output, agentName: agent.name)
            }

            let port = try findFreePort()
            let (process, diagnostics) = try bootServer(nodePath: nodePath, serverPath: serverPath, dbPath: dbPath, port: port)
            bootedProcess = process
            let baseURL = URL(string: "http://127.0.0.1:\(port)")!

            do {
                try await waitForReadiness(baseURL: baseURL)
            } catch {
                throw HarnessError.serverDidNotBecomeReady(lastError: error, diagnostics: diagnostics.contents)
            }

            return JournalServerHarness(
                baseURL: baseURL, process: process, tempDir: tempDir, dbPath: dbPath,
                serverPath: serverPath, nodePath: nodePath, agentTokens: tokens, diagnostics: diagnostics
            )
        } catch {
            if let bootedProcess {
                bootedProcess.terminate()
                bootedProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: tempDir)
            throw error
        }
    }

    /// Provisions an additional user against the already-running server.
    /// Safe under WAL mode (see the type-level doc comment); provided for
    /// completeness, though the harness's own `start()` provisions
    /// everything up front.
    func addUser(_ name: String, password: String) throws {
        _ = try Self.runAdminCLI(nodePath: nodePath, serverPath: serverPath, dbPath: dbPath,
                                 arguments: ["user", "add", name, "--password", password])
    }

    /// Provisions an additional agent against the already-running server and
    /// records its token in `agentTokens`.
    @discardableResult
    func addAgent(user: String, name: String) throws -> String {
        let output = try Self.runAdminCLI(nodePath: nodePath, serverPath: serverPath, dbPath: dbPath,
                                          arguments: ["agent", "add", user, name])
        let token = try Self.parseAgentToken(output, agentName: name)
        agentTokens[name] = token
        return token
    }

    /// Terminates the server subprocess and deletes the temp DB directory.
    /// Call from `defer` / `tearDown` — idempotent-ish (safe to call once).
    func stop() {
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Repo / node discovery

    private static func requireServerRepo() throws -> String {
        let path = ProcessInfo.processInfo.environment["MATRON_JOURNAL_PATH"]
            ?? (NSHomeDirectory() + "/Dev/matron-journal")
        guard FileManager.default.fileExists(atPath: path + "/src/server.js") else {
            throw XCTSkip("matron-journal checkout not found at \(path) — set MATRON_JOURNAL_PATH to override")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path + "/node_modules", isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw XCTSkip("matron-journal node_modules missing at \(path) — run `npm install` there once")
        }
        return path
    }

    /// `/usr/bin/env node` only works if `node` is on the CURRENT process's
    /// `PATH`. When `node` comes from nvm (a version-specific directory
    /// added to `PATH` only by `~/.zshrc`'s `nvm.sh` sourcing), the xctest
    /// process spawned by `xcodebuild` does not inherit that PATH —
    /// `/usr/bin/env node` 127s there even though it works fine from an
    /// interactive Bash session. `~/.zshrc` is only read by an
    /// *interactive* zsh (`-i`), not merely a login one (`-l -c` reads
    /// `.zprofile`/`.zlogin`, never `.zshrc`) — verified empirically: with a
    /// clean environment, `/bin/zsh -l -c 'command -v node'` fails to find
    /// nvm's node while `/bin/zsh -i -c 'command -v node'` succeeds.
    /// Resolving the absolute path once this way (independent of whatever
    /// PATH the xctest host process happens to have) and invoking that
    /// absolute path directly for every subsequent node call sidesteps the
    /// whole PATH question.
    ///
    /// The interactive shell is a subprocess of unknown provenance — a
    /// hung/blocking `.zshrc` (network call, prompt, whatever) must not be
    /// able to wedge the whole test job forever, so it's bounded to 10s via
    /// `run(withTimeout:_:)`. On a timeout (or any other failure to resolve
    /// via the shell) this falls through to a short list of common
    /// absolute install locations before giving up with `XCTSkip`. The
    /// result (success AND failure) is cached in a process-wide static so
    /// this cost — normally a fork/exec plus up to 10s of waiting in the
    /// worst case — is paid at most once per test process, not once per
    /// `start()` call.
    private static let nodePathLock = NSLock()
    private static var cachedNodePathResult: Result<String, Error>?

    private static func resolveNodePath() throws -> String {
        nodePathLock.lock()
        defer { nodePathLock.unlock() }
        if let cached = cachedNodePathResult {
            return try cached.get()
        }
        let result = Result { try resolveNodePathUncached() }
        cachedNodePathResult = result
        return try result.get()
    }

    private static func resolveNodePathUncached() throws -> String {
        if let overridden = ProcessInfo.processInfo.environment["MATRON_NODE_PATH"],
           FileManager.default.isExecutableFile(atPath: overridden) {
            return overridden
        }
        if let viaShell = resolveNodePathViaInteractiveShell(timeout: 10) {
            return viaShell
        }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw XCTSkip("node not resolvable via `zsh -i -c 'command -v node'` (timed out or failed), MATRON_NODE_PATH, or common install paths — set MATRON_NODE_PATH to override")
    }

    /// Returns `nil` (never throws) on timeout or any resolution failure —
    /// callers fall through to the next link in the chain.
    private static func resolveNodePathViaInteractiveShell(timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-i", "-c", "command -v node"]
        // Deliberately minimal + explicit rather than inherited: this must
        // work regardless of what PATH/HOME the xctest host process has.
        process.environment = ["HOME": NSHomeDirectory()]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        guard run(withTimeout: timeout, process) else { return nil }

        let path = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path)
        else { return nil }
        return path
    }

    /// Runs `process`, waiting at most `seconds` for it to exit on its own.
    /// Returns `false` (having already sent `terminate()` and given it a
    /// short grace period to die) if it timed out, or if it couldn't even
    /// be launched. Used to bound subprocesses whose behavior (e.g. an
    /// interactive shell sourcing an unknown `.zshrc`) isn't fully within
    /// this harness's control.
    private static func run(withTimeout seconds: TimeInterval, _ process: Process) -> Bool {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return false }
        if done.wait(timeout: .now() + seconds) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 2)
            return false
        }
        return true
    }

    // MARK: Admin CLI

    private static func runAdminCLI(
        nodePath: String, serverPath: String, dbPath: String, arguments: [String]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: nodePath)
        process.arguments = ["bin/matron-admin.js"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: serverPath)
        var env = ProcessInfo.processInfo.environment
        env["MATRON_DB"] = dbPath
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let combined = String(decoding: outData, as: UTF8.self) + String(decoding: errData, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw HarnessError.adminCLIFailed(arguments: arguments, output: combined)
        }
        return combined
    }

    private static func parseAgentToken(_ output: String, agentName: String) throws -> String {
        // Matches "agent <name> token: <64hex>" (bin/matron-admin.js's exact
        // format — printed once, so this is the only place the value exists).
        guard let range = output.range(of: #"token:\s*([0-9a-f]{64})"#, options: .regularExpression) else {
            throw HarnessError.tokenNotFound(agent: agentName, output: output)
        }
        let matched = output[range]
        guard let hexRange = matched.range(of: #"[0-9a-f]{64}"#, options: .regularExpression) else {
            throw HarnessError.tokenNotFound(agent: agentName, output: output)
        }
        return String(matched[hexRange])
    }

    // MARK: Free port

    private static func findFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HarnessError.portProbeFailed("socket() failed (errno \(errno))") }
        defer { Darwin.close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        let bindResult = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw HarnessError.portProbeFailed("bind() failed (errno \(errno))") }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard getNameResult == 0 else { throw HarnessError.portProbeFailed("getsockname() failed (errno \(errno))") }
        return UInt16(bigEndian: boundAddr.sin_port)
    }

    // MARK: Server boot

    /// Boots `node src/server.js` wrapped in a small `/bin/sh` watchdog
    /// rather than as a direct child, so the node process can't outlive
    /// this harness even if the xctest host is SIGKILLed (a signal
    /// `stop()`/`defer`/`terminate()` never gets a chance to run for).
    ///
    /// The watchdog does two things:
    /// - `trap ... TERM INT` handles the normal `stop()` path: `stop()`
    ///   calls `Process.terminate()`, which sends SIGTERM to this shell
    ///   (not to node); the trap forwards that into a `kill` of the node
    ///   child before the shell exits.
    /// - The `kill -0 "$PPID"` loop handles the SIGKILL case, where the
    ///   shell itself is never signaled: `$PPID` is captured by the shell
    ///   at startup and does NOT track re-parenting, so once the original
    ///   parent (the xctest process) is gone — even via SIGKILL, which
    ///   bypasses all Swift-side cleanup — `kill -0 "$PPID"` starts failing
    ///   and the loop kills the orphaned node child itself, within ~1s.
    ///
    /// (Considered instead: a pid-file-based sweep of stale runs at the
    /// start of `start()`. Rejected as strictly more moving parts for the
    /// same guarantee — this needs no shared/discoverable state across
    /// runs, just a watchdog for whichever run is problematic.)
    private static func bootServer(
        nodePath: String, serverPath: String, dbPath: String, port: UInt16
    ) throws -> (Process, DiagnosticsBuffer) {
        let watchdogScript = """
        trap 'kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; exit 0' TERM INT
        "\(nodePath)" src/server.js &
        SERVER=$!
        while kill -0 "$PPID" 2>/dev/null; do
            sleep 1
        done
        kill "$SERVER" 2>/dev/null
        wait "$SERVER" 2>/dev/null
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdogScript]
        process.currentDirectoryURL = URL(fileURLWithPath: serverPath)
        var env = ProcessInfo.processInfo.environment
        env["MATRON_DB"] = dbPath
        env["MATRON_PORT"] = String(port)
        env["MATRON_BIND"] = "127.0.0.1"
        process.environment = env

        let diagnostics = DiagnosticsBuffer()
        let outPipe = Pipe()
        let errPipe = Pipe()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { diagnostics.append(String(decoding: data, as: UTF8.self)) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { diagnostics.append(String(decoding: data, as: UTF8.self)) }
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        return (process, diagnostics)
    }

    /// Polls `GET /snapshot` (expects 401 — proof the HTTP layer is up and
    /// enforcing auth) until it succeeds `consecutiveSuccessesRequired`
    /// times in a row, each on a brand-new, non-keep-alive connection.
    ///
    /// A single success is not enough: empirically, a Node server whose
    /// `listen()` callback JUST fired can accept and correctly answer one
    /// connection and then reset the very next one moments later (observed
    /// as `loginPassword()` throwing `.transport("The network connection
    /// was lost.")` immediately after this poll had already returned
    /// success) — the accept queue/backlog needs a beat to settle. Requiring
    /// a few clean-in-a-row probes, each forced onto its own socket via
    /// `ephemeralConfiguration` (no connection-pool reuse from the prior
    /// probe masking the same issue), reliably rides out that window.
    private static func waitForReadiness(
        baseURL: URL, timeout: TimeInterval = 5, consecutiveSuccessesRequired: Int = 3
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = baseURL.appendingPathComponent("snapshot")
        let probeSession = URLSession(configuration: .ephemeral)
        var lastError: Error?
        var consecutiveSuccesses = 0
        while Date() < deadline {
            do {
                var request = URLRequest(url: url)
                request.setValue("close", forHTTPHeaderField: "Connection")
                let (_, response) = try await probeSession.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    consecutiveSuccesses += 1
                    if consecutiveSuccesses >= consecutiveSuccessesRequired { return }
                    try await Task.sleep(for: .milliseconds(30))
                    continue
                }
                consecutiveSuccesses = 0
                lastError = HarnessError.portProbeFailed("unexpected status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            } catch {
                consecutiveSuccesses = 0
                lastError = error
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw lastError ?? HarnessError.portProbeFailed("readiness poll exhausted with no recorded error")
    }
}

/// Thread-safe accumulator for a subprocess's interleaved stdout/stderr,
/// used only for diagnostics when the harness fails to become ready.
final class DiagnosticsBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    var contents: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }
}

/// A raw `URLSessionWebSocketTask` playing the *agent* side of the wire
/// protocol against a real matron-journal server — deliberately independent
/// of `JournalConnection`/`JournalSyncEngine` (those are the code under
/// test, from the client's POV). Wire shapes per the server (`src/ws.js`):
/// `convo_upsert {op,convo_id,title?,session_state?}`, `publish
/// {op,convo_id,type,payload,idem_key?}`, `stream
/// {op,convo_id,message_ref,replace_text?,text?}`, `finalize
/// {op,convo_id,message_ref,type?,payload}`. Agents are live-only listeners
/// (`hello {op:"hello",token,cursor:null}` — no replay).
final class FakeAgent: @unchecked Sendable {
    enum FakeAgentError: Error, CustomStringConvertible {
        case helloRejected(code: String)
        case timeout(String)
        var description: String {
            switch self {
            case let .helloRejected(code): return "agent hello rejected by server: \(code)"
            case let .timeout(what): return "timed out waiting for \(what)"
            }
        }
    }

    private let task: URLSessionWebSocketTask
    private let urlSession: URLSession
    private let lock = NSLock()
    private var receivedFrames: [[String: Any]] = []
    private var pumpTask: Task<Void, Never>?

    private init(task: URLSessionWebSocketTask, urlSession: URLSession) {
        self.task = task
        self.urlSession = urlSession
    }

    /// Opens `/ws`, sends the live-only agent hello, and waits for
    /// `hello_ok` (throws `.helloRejected` on a control `error` frame, e.g.
    /// a bad/revoked token).
    static func connect(baseURL: URL, token: String) async throws -> FakeAgent {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/ws"
        let urlSession = URLSession(configuration: .default)
        let task = urlSession.webSocketTask(with: components.url!)
        task.resume()
        let agent = FakeAgent(task: task, urlSession: urlSession)
        agent.startPump()
        try await agent.sendRaw(["op": "hello", "token": token, "cursor": NSNull()])
        try await agent.waitForControlHello()
        return agent
    }

    func convoUpsert(id: String, title: String? = nil, sessionState: String? = nil) async throws {
        var obj: [String: Any] = ["op": "convo_upsert", "convo_id": id]
        if let title { obj["title"] = title }
        if let sessionState { obj["session_state"] = sessionState }
        try await sendRaw(obj)
    }

    func publish(convoID: String, type: String, payload: [String: Any], idemKey: String? = nil) async throws {
        var obj: [String: Any] = ["op": "publish", "convo_id": convoID, "type": type, "payload": payload]
        if let idemKey { obj["idem_key"] = idemKey }
        try await sendRaw(obj)
    }

    func stream(convoID: String, ref: String, replaceText: String) async throws {
        try await sendRaw(["op": "stream", "convo_id": convoID, "message_ref": ref, "replace_text": replaceText])
    }

    func finalize(convoID: String, ref: String, body: [String: Any], type: String = "text") async throws {
        try await sendRaw(["op": "finalize", "convo_id": convoID, "message_ref": ref, "type": type, "payload": body])
    }

    /// Every decoded frame received so far (control + journal + ephemeral).
    func framesSnapshot() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return receivedFrames
    }

    /// Polls `framesSnapshot()` until a frame matches `predicate` or
    /// `timeout` elapses.
    func waitForFrame(
        timeout: TimeInterval, matching predicate: @escaping ([String: Any]) -> Bool
    ) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = framesSnapshot().first(where: predicate) { return match }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw FakeAgentError.timeout("a matching frame")
    }

    func close() {
        pumpTask?.cancel()
        task.cancel(with: .goingAway, reason: nil)
    }

    // MARK: Internals

    private func waitForControlHello() async throws {
        let frame = try await waitForFrame(timeout: 5) { obj in
            obj["kind"] as? String == "control"
        }
        if frame["op"] as? String == "error" {
            throw FakeAgentError.helloRejected(code: frame["code"] as? String ?? "unknown")
        }
    }

    private func startPump() {
        pumpTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let message = try await self.task.receive()
                    let text: String
                    switch message {
                    case .string(let string): text = string
                    case .data(let data): text = String(decoding: data, as: UTF8.self)
                    @unknown default: continue
                    }
                    guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
                    else { continue }
                    self.lock.lock()
                    self.receivedFrames.append(obj)
                    self.lock.unlock()
                } catch {
                    return
                }
            }
        }
    }

    private func sendRaw(_ obj: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: obj)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

/// Minimal in-memory `SessionStore` for tests that need a
/// `JournalAuthService` but don't care about on-disk persistence across
/// process launches.
final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    func set(_ value: String, forKey key: String) throws {
        lock.lock()
        storage[key] = value
        lock.unlock()
    }

    func get(key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    func delete(key: String) throws {
        lock.lock()
        storage.removeValue(forKey: key)
        lock.unlock()
    }
}

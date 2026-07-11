import XCTest
import MatronAuth
import MatronJournal
import MatronModels

/// Integration tests driving the real matron-journal server (see
/// `JournalServerHarness`). Precondition: `cd ~/Dev/matron-journal &&
/// npm install` once. Each test boots its own harness (fresh temp SQLite
/// DB, fresh free port) so tests never share server-side state.
///
/// `JournalServerHarness.start()` throws `XCTSkip` when the server checkout,
/// `node`, or `node_modules` are missing — everything else (a real startup
/// failure) is a hard error, not a skip: on a properly set-up machine these
/// tests must actually run.
final class JournalServerTests: XCTestCase {
    private let ownSender = "user:dan"

    // MARK: Test 1 — sign-in, snapshot, live round-trip

    func testSignInSnapshotLiveRoundTrip() async throws {
        let harness = try await JournalServerHarness.start(
            users: [.init("dan", password: "pw")],
            agents: [.init(user: "dan", name: "dev-2")]
        )
        defer { harness.stop() }
        let agentToken = try XCTUnwrap(harness.agentTokens["dev-2"])

        let auth = JournalAuthService(sessionStore: InMemorySessionStore())
        let session = try await auth.loginPassword(
            homeserverURL: harness.baseURL, username: "dan", password: "pw",
            initialDeviceDisplayName: "integration-test-client"
        )

        let store = try JournalStore(databaseURL: nil, ownSender: ownSender)
        let api = JournalAPI(serverURL: harness.baseURL, token: session.accessToken)
        let engine = JournalSyncEngine(
            api: api, store: store, connector: URLSessionWebSocketConnector(),
            token: session.accessToken, ownSender: ownSender, search: nil,
            backoffBaseSeconds: 0.25
        )
        await engine.beginSync()
        try await engine.waitUntilReady()
        defer { Task { await engine.endSync() } }

        let agent = try await FakeAgent.connect(baseURL: harness.baseURL, token: agentToken)
        defer { agent.close() }

        try await agent.convoUpsert(id: "sess-1", title: "Session 1", sessionState: "running")
        for i in 1...3 {
            try await agent.publish(convoID: "sess-1", type: "text", payload: ["body": "hello \(i)"])
        }

        try await waitUntil(timeout: 5, description: "3 published texts to converge into the store") {
            try (store.events(convoID: "sess-1").filter { $0.type == JournalEventType.text }).count >= 3
        }
        let texts = try store.events(convoID: "sess-1")
            .filter { $0.type == JournalEventType.text }
            .sorted { $0.seq < $1.seq }
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(texts.map { $0.payload["body"] as? String }, ["hello 1", "hello 2", "hello 3"])
        XCTAssertTrue(texts.allSatisfy { $0.sender == "agent:dev-2" })

        // Client -> server -> agent: the engine's own send must reach the
        // agent's live socket as a journal frame (same fan-out the server
        // uses for every device of the user).
        try await engine.sendOp(.send(convoID: "sess-1", body: "from client", localID: "local-1"))
        let received = try await agent.waitForFrame(timeout: 5) { frame in
            frame["kind"] as? String == "journal"
                && (frame["payload"] as? [String: Any])?["body"] as? String == "from client"
        }
        XCTAssertEqual(received["sender"] as? String, ownSender)
        XCTAssertEqual(received["type"] as? String, JournalEventType.text)
    }

    // MARK: Test 2 — cursor resume across an engine restart

    func testResumeAfterEngineRestart() async throws {
        let harness = try await JournalServerHarness.start(
            users: [.init("dan", password: "pw")],
            agents: [.init(user: "dan", name: "dev-2")]
        )
        defer { harness.stop() }
        let agentToken = try XCTUnwrap(harness.agentTokens["dev-2"])

        let auth = JournalAuthService(sessionStore: InMemorySessionStore())
        let session = try await auth.loginPassword(
            homeserverURL: harness.baseURL, username: "dan", password: "pw",
            initialDeviceDisplayName: "integration-test-client"
        )

        let store = try JournalStore(databaseURL: nil, ownSender: ownSender)
        let api = JournalAPI(serverURL: harness.baseURL, token: session.accessToken)

        let agent = try await FakeAgent.connect(baseURL: harness.baseURL, token: agentToken)
        defer { agent.close() }
        try await agent.convoUpsert(id: "sess-2", title: "Session 2", sessionState: "running")

        let engine1 = JournalSyncEngine(
            api: api, store: store, connector: URLSessionWebSocketConnector(),
            token: session.accessToken, ownSender: ownSender, search: nil,
            backoffBaseSeconds: 0.25
        )
        await engine1.beginSync()
        try await engine1.waitUntilReady()

        for i in 1...5 {
            try await agent.publish(convoID: "sess-2", type: "text", payload: ["body": "first-\(i)"])
        }
        try await waitUntil(timeout: 5, description: "first 5 texts to converge") {
            try store.events(convoID: "sess-2").filter { $0.type == JournalEventType.text }.count >= 5
        }
        await engine1.endSync()

        for i in 1...5 {
            try await agent.publish(convoID: "sess-2", type: "text", payload: ["body": "second-\(i)"])
        }
        // Engine 1 is stopped — these 5 must NOT have reached the store yet.
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(try store.events(convoID: "sess-2").filter { $0.type == JournalEventType.text }.count, 5,
                       "events published while the engine was stopped must not appear until resume")

        // A brand-new engine on the SAME store/DB must resume from the
        // persisted cursor across this process-lifecycle boundary.
        let engine2 = JournalSyncEngine(
            api: api, store: store, connector: URLSessionWebSocketConnector(),
            token: session.accessToken, ownSender: ownSender, search: nil,
            backoffBaseSeconds: 0.25
        )
        await engine2.beginSync()
        try await engine2.waitUntilReady()
        defer { Task { await engine2.endSync() } }

        try await waitUntil(timeout: 5, description: "all 10 texts to converge after resume") {
            try store.events(convoID: "sess-2").filter { $0.type == JournalEventType.text }.count >= 10
        }
        let texts = try store.events(convoID: "sess-2")
            .filter { $0.type == JournalEventType.text }
            .sorted { $0.seq < $1.seq }
        XCTAssertEqual(texts.map { $0.payload["body"] as? String },
                      (1...5).map { "first-\($0)" } + (1...5).map { "second-\($0)" },
                      "resume must be gap-free and exactly-once, in seq order")
    }

    // MARK: Test 3 — chaos resume against the real server

    /// Client-side headline test mirroring the server's own chaos suite:
    /// 200 events published with 1ms spacing while `ChaosConnector` (a
    /// `WebSocketConnecting` decorator over the real
    /// `URLSessionWebSocketConnector`) force-closes the socket after a
    /// random 10-40 *journal* frames on every connect, driving repeated
    /// reconnects. The store must still converge to an exact, gap-free,
    /// duplicate-free copy of the 200 published texts.
    ///
    /// Note: the convo also carries a `session_status` event (from
    /// `convo_upsert`'s `session_state`), so raw seq values aren't
    /// contiguous 1...200 for this convo's full event list — the assertion
    /// is scoped to the published `text` events specifically, per the task
    /// brief.
    func testChaosResumeAgainstRealServer() async throws {
        let harness = try await JournalServerHarness.start(
            users: [.init("dan", password: "pw")],
            agents: [.init(user: "dan", name: "dev-2")]
        )
        defer { harness.stop() }
        let agentToken = try XCTUnwrap(harness.agentTokens["dev-2"])

        let auth = JournalAuthService(sessionStore: InMemorySessionStore())
        let session = try await auth.loginPassword(
            homeserverURL: harness.baseURL, username: "dan", password: "pw",
            initialDeviceDisplayName: "integration-test-client"
        )

        let store = try JournalStore(databaseURL: nil, ownSender: ownSender)
        let api = JournalAPI(serverURL: harness.baseURL, token: session.accessToken)
        let connector = ChaosConnector()
        let engine = JournalSyncEngine(
            api: api, store: store, connector: connector,
            token: session.accessToken, ownSender: ownSender, search: nil,
            backoffBaseSeconds: 0.05
        )
        await engine.beginSync()
        defer { Task { await engine.endSync() } }

        let agent = try await FakeAgent.connect(baseURL: harness.baseURL, token: agentToken)
        defer { agent.close() }
        try await agent.convoUpsert(id: "sess-chaos", title: "Chaos", sessionState: "running")

        let total = 200
        for i in 1...total {
            try await agent.publish(convoID: "sess-chaos", type: "text", payload: ["body": "chaos-\(i)"])
            try await Task.sleep(for: .milliseconds(1))
        }

        try await waitUntil(timeout: 30, description: "all 200 published texts to converge") {
            try store.events(convoID: "sess-chaos").filter { $0.type == JournalEventType.text }.count >= total
        }
        let texts = try store.events(convoID: "sess-chaos")
            .filter { $0.type == JournalEventType.text }
            .sorted { $0.seq < $1.seq }
        let bodies = texts.map { $0.payload["body"] as? String }
        XCTAssertEqual(bodies.count, total, "no dupes, no drops")
        XCTAssertEqual(bodies, (1...total).map { "chaos-\($0)" }, "gap-free, exactly-once, in seq order")
        XCTAssertEqual(Set(bodies.compactMap { $0 }).count, total, "no duplicate bodies")
        XCTAssertGreaterThan(connector.connectCount, 1, "chaos must actually force at least one reconnect")
    }

    // MARK: Helpers

    private func waitUntil(
        timeout: TimeInterval, description: String, _ condition: () throws -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("condition not met within \(timeout)s: \(description)")
    }
}

/// Wraps the real `URLSessionWebSocketConnector` and force-closes the
/// underlying socket after a random 10-40 *journal* frames on every
/// connect, forcing the sync engine's normal reconnect/resume path against
/// a genuinely flaky transport — the client-side mirror of
/// `JournalSyncEngineTests.ChaosServerConnector` (fake-socket unit test),
/// but here against the real server over a real socket.
final class ChaosConnector: WebSocketConnecting, @unchecked Sendable {
    private let inner = URLSessionWebSocketConnector()
    private let lock = NSLock()
    private(set) var connectCount = 0

    func connect(to url: URL) async throws -> any WebSocketConnection {
        lock.lock()
        connectCount += 1
        lock.unlock()
        let real = try await inner.connect(to: url)
        return ChaosConnection(inner: real)
    }
}

final class ChaosConnection: WebSocketConnection, @unchecked Sendable {
    private let inner: any WebSocketConnection
    private let cutAfter = Int.random(in: 10...40)
    private let lock = NSLock()
    private var journalFramesSeen = 0

    init(inner: any WebSocketConnection) {
        self.inner = inner
    }

    func sendText(_ text: String) async throws {
        try await inner.sendText(text)
    }

    func receiveText() async throws -> String {
        let text = try await inner.receiveText()
        // Only journal frames count toward the cut — control/ephemeral
        // frames (hello_ok, etc.) shouldn't shorten the "real" replay
        // window being chaos-tested.
        if let frame = ServerFrame.decode(text), case .journal = frame {
            lock.lock()
            journalFramesSeen += 1
            let shouldClose = journalFramesSeen >= cutAfter
            lock.unlock()
            if shouldClose { inner.close() }
        }
        return text
    }

    func ping() async throws { try await inner.ping() }
    func close() { inner.close() }
}

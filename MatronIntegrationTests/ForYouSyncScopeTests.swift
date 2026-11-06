import XCTest
import MatronAuth
import MatronJournal

/// The `forYou` sync scope against a real journal: the socket carries the
/// tracker and not conversation content, and an opened conversation is
/// fetched, then followed live.
final class ForYouSyncScopeTests: XCTestCase {
    private let ownSender = "user:alice"

    func testForYouFollowsTheTrackerAndFetchesAnOpenedConversation() async throws {
        let harness = try await JournalServerHarness.start(
            users: [.init("alice", password: "pw")],
            agents: [.init(user: "alice", name: "box-2")]
        )
        defer { harness.stop() }
        let agentToken = try XCTUnwrap(harness.agentTokens["box-2"])
        let agent = try await FakeAgent.connect(baseURL: harness.baseURL, token: agentToken)
        defer { agent.close() }
        try await agent.convoUpsert(id: "busy", title: "Busy", sessionState: "running")

        let auth = JournalAuthService(sessionStore: InMemorySessionStore())
        let session = try await auth.loginPassword(
            homeserverURL: harness.baseURL, username: "alice", password: "pw",
            initialDeviceDisplayName: "phone")
        // A store that already followed everything for a while.
        let store = try JournalStore(databaseURL: nil, ownSender: ownSender)
        let api = JournalAPI(serverURL: harness.baseURL, token: session.accessToken)
        var engine = JournalSyncEngine(api: api, store: store, connector: URLSessionWebSocketConnector(),
                                       token: session.accessToken, ownSender: ownSender, search: nil,
                                       backoffBaseSeconds: 0.25)
        await engine.beginSync()
        try await engine.waitUntilReady()
        for i in 1...20 {
            try await agent.publish(convoID: "busy", type: "text", payload: ["body": "before \(i)"])
        }
        try await waitUntil("the first 20 texts") { try self.texts(store, "busy").count == 20 }
        await engine.endSync()

        // Now For you only.
        try store.markForYouStart()
        engine = JournalSyncEngine(api: api, store: store, connector: URLSessionWebSocketConnector(),
                                   token: session.accessToken, ownSender: ownSender, search: nil,
                                   backoffBaseSeconds: 0.25, syncScope: .forYou)
        // Content and a tracker item while the phone is away.
        for i in 1...5 {
            try await agent.publish(convoID: "busy", type: "text", payload: ["body": "away \(i)"])
        }
        try await createItem(harness.baseURL, token: agentToken, convoID: "busy", title: "Which plan?")
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await waitUntil("the item marker") {
            try store.events(convoID: "busy").contains { $0.type == JournalEventType.item }
        }
        XCTAssertEqual(try texts(store, "busy").count, 20, "the socket carried no conversation content")

        // Live, still not viewed: nothing.
        try await agent.publish(convoID: "busy", type: "text", payload: ["body": "unviewed"])
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(try texts(store, "busy").count, 20)

        // Opened: fetched, then followed live.
        await engine.registerViewer(UUID(), convoID: "busy")
        try await waitUntil("the fetch") { try self.texts(store, "busy").count == 26 }
        try await agent.publish(convoID: "busy", type: "text", payload: ["body": "while open"])
        try await waitUntil("the live text") {
            try self.texts(store, "busy").last?.payload["body"] as? String == "while open"
        }
        XCTAssertEqual(try texts(store, "busy").count, 27)
        await engine.endSync()
    }

    // MARK: Helpers

    private func texts(_ store: JournalStore, _ convoID: String) throws -> [JournalEvent] {
        // Not the journal's text mirror of an item marker, kept for old clients.
        try store.events(convoID: convoID)
            .filter { $0.type == JournalEventType.text && $0.payload["fallback_for"] == nil }
            .sorted { $0.seq < $1.seq }
    }

    private func createItem(_ base: URL, token: String, convoID: String, title: String) async throws {
        var request = URLRequest(url: base.appendingPathComponent("items"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["kind": "question", "title": title, "convo_id": convoID])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 201)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 8,
                           _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("condition not met within \(timeout)s: \(description)")
    }
}

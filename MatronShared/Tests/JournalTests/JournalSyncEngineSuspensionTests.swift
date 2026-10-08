import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// The reconnect loop parks while the host has the databases suspended.
/// Without it every connect's first replayed write was refused and the loop
/// reconnected about once a second — a handshake, a replay and App Group WAL
/// reads per round, for as long as the suspension lasted.
final class JournalSyncEngineSuspensionTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Bool
        init(_ value: Bool) { _value = value }
        var value: Bool {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

    private func journalLine(_ seq: Int64) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"c1","ts":\#(seq * 1000),"sender":"agent:a","type":"text","payload":{"body":"m\#(seq)"}}"#
    }

    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func seededStore() throws -> JournalStore {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        return store
    }

    private func makeEngine(store: JournalStore, connector: any WebSocketConnecting,
                            suspended: Flag) -> JournalSyncEngine {
        JournalSyncEngine(api: JournalAPI(serverURL: URL(string: "https://x")!), store: store,
                          connector: connector, token: "t", ownSender: "user:alice", search: nil,
                          backoffBaseSeconds: 0.01,
                          databasesSuspended: { suspended.value })
    }

    func testDoesNotConnectWhileSuspendedAndConnectsOnResume() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(1))
        socket.serve(journalLine(1))
        let connector = FakeConnector([socket])
        let suspended = Flag(true)
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector, suspended: suspended)
        await engine.beginSync()

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(connector.connectCount, 0, "a suspended engine must not connect")

        suspended.value = false
        await engine.databasesResumed()
        try await engine.waitUntilReady()
        XCTAssertEqual(connector.connectCount, 1)
        XCTAssertEqual(store.cursor, 1)
        await engine.endSync()
    }

    func testSocketDeathWhileSuspendedParksInsteadOfReconnecting() async throws {
        let first = FakeWebSocketConnection()
        first.serve(helloOK(1))
        first.serve(journalLine(1))
        let second = FakeWebSocketConnection()
        second.serve(helloOK(2))
        second.serve(journalLine(2))
        let connector = FakeConnector([first, second])
        let suspended = Flag(false)
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector, suspended: suspended)
        await engine.beginSync()
        try await engine.waitUntilReady()

        suspended.value = true
        first.closeFromServer()
        // With a 10 ms backoff base an unparked loop would reconnect (and,
        // against a real suspended store, storm) well inside this window.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(connector.connectCount, 1, "no reconnect while the databases are suspended")

        // A nudge (scene becoming active) with the suspension still in force
        // must not break the park either.
        await engine.nudge()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(connector.connectCount, 1)

        suspended.value = false
        await engine.databasesResumed()
        for _ in 0..<200 where store.cursor < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connector.connectCount, 2)
        XCTAssertEqual(store.cursor, 2)
        await engine.endSync()
    }

    func testEndSyncStopsAParkedLoop() async throws {
        let connector = FakeConnector([])
        let engine = makeEngine(store: try seededStore(), connector: connector, suspended: Flag(true))
        await engine.beginSync()
        try await Task.sleep(for: .milliseconds(100))
        await engine.endSync()
        let running = await engine.isRunning
        XCTAssertFalse(running)
        XCTAssertEqual(connector.connectCount, 0)
    }
}

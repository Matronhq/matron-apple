import XCTest
import MatronModels
@testable import MatronJournal

final class JournalSyncEngineTests: XCTestCase {
    private func journalLine(_ seq: Int64, convo: String = "c1", sender: String = "agent:a",
                             type: String = "text", body: String = "m") -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"\#(sender)","type":"\#(type)","payload":{"body":"\#(body)\#(seq)"}}"#
    }

    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func makeEngine(store: JournalStore, connector: FakeConnector) -> JournalSyncEngine {
        let api = JournalAPI(serverURL: URL(string: "https://x")!) // HTTP unused in these tests: store pre-seeded
        return JournalSyncEngine(api: api, store: store, connector: connector,
                                 token: "t", ownSender: "user:dan", search: nil,
                                 backoffBaseSeconds: 0.01)
    }

    /// Pre-seed the store so the engine skips the cold /snapshot fetch.
    private func seededStore() throws -> JournalStore {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        return store
    }

    func testReplayAppliesToStoreAndReachesRunning() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(3))
        socket.serve(journalLine(1))
        socket.serve(journalLine(2))
        socket.serve(journalLine(3))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(store.cursor, 3)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2, 3])
        await engine.endSync()
    }

    func testReconnectResumesFromCursorAfterSocketDeath() async throws {
        let first = FakeWebSocketConnection()
        first.serve(helloOK(2))
        first.serve(journalLine(1))
        first.serve(journalLine(2))
        let second = FakeWebSocketConnection()
        second.serve(helloOK(4))
        second.serve(journalLine(3))
        second.serve(journalLine(4))
        let store = try seededStore()
        let connector = FakeConnector([first, second])
        let engine = makeEngine(store: store, connector: connector)
        await engine.beginSync()
        try await engine.waitUntilReady()
        first.closeFromServer()

        // wait for the second connection to drain
        for _ in 0..<200 where store.cursor < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 4)
        XCTAssertEqual(connector.connectCount, 2)
        // second hello must resume from cursor 2
        let hello = try XCTUnwrap(second.sent.first.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        })
        XCTAssertEqual(hello["cursor"] as? Int64, 2)
        await engine.endSync()
    }

    func testDuplicateReplayFramesAreIdempotent() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(2))
        socket.serve(journalLine(1))
        socket.serve(journalLine(1)) // duplicate
        socket.serve(journalLine(2))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(try store.events(convoID: "c1").count, 2)
        await engine.endSync()
    }

    func testEphemeralFanOut() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        var iterator = engine.ephemerals(convoID: "c1").makeAsyncIterator()
        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m1","replace_text":"working…"}"#)
        let update = await iterator.next()
        XCTAssertEqual(update?.replaceText, "working…")
        await engine.endSync()
    }

    func testStateStreamTransitions() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        var iterator = engine.stateStream().makeAsyncIterator()
        let initial = await iterator.next()
        XCTAssertEqual(initial, .connecting)
        await engine.beginSync()
        var seen: [SyncConnectionState] = []
        for _ in 0..<3 {
            guard let state = await iterator.next() else { break }
            seen.append(state)
            if state == .running { break }
        }
        XCTAssertTrue(seen.contains(.running), "expected .running, saw \(seen)")
        await engine.endSync()
    }

    /// Chaos-style: 60 events over connections that die every ~15 frames.
    /// The store must converge to an exact, gap-free prefix copy.
    func testChaosResumeConvergence() async throws {
        var sockets: [FakeWebSocketConnection] = []
        var next: Int64 = 1
        while next <= 60 {
            let socket = FakeWebSocketConnection()
            socket.serve(helloOK(60))
            let batchEnd = min(next + 14, 60)
            // overlap: re-serve up to 3 already-delivered events (server replays > cursor;
            // the fake approximates a race by double-sending — apply must dedupe)
            for seq in max(1, next - 3)...batchEnd { socket.serve(journalLine(seq)) }
            next = batchEnd + 1
            sockets.append(socket)
        }
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector(sockets))
        await engine.beginSync()
        for (index, socket) in sockets.enumerated() where index < sockets.count - 1 {
            let target = Int64(min((index + 1) * 15, 60))
            for _ in 0..<300 where store.cursor < target {
                try await Task.sleep(for: .milliseconds(10))
            }
            socket.closeFromServer()
        }
        for _ in 0..<500 where store.cursor < 60 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 60)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), Array(1...60), "gap-free exactly-once")
        await engine.endSync()
    }
}

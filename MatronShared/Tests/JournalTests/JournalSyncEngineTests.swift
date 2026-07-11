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

    private func makeEngine(
        store: JournalStore, connector: any WebSocketConnecting, backoffBaseSeconds: Double = 0.01
    ) -> JournalSyncEngine {
        let api = JournalAPI(serverURL: URL(string: "https://x")!) // HTTP unused in these tests: store pre-seeded
        return JournalSyncEngine(api: api, store: store, connector: connector,
                                 token: "t", ownSender: "user:dan", search: nil,
                                 backoffBaseSeconds: backoffBaseSeconds)
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

    /// Chaos-style: a cursor-aware fake server that cuts the connection at a
    /// random point mid-replay on every connect (see ChaosServerConnector).
    /// The store must still converge to an exact, gap-free prefix copy.
    func testChaosResumeConvergence() async throws {
        let journal = (1...200).map { journalLine(Int64($0)) }
        let connector = ChaosServerConnector(journal: journal, headSeq: 200)
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector, backoffBaseSeconds: 0.001)
        await engine.beginSync()
        for _ in 0..<3000 where store.cursor < 200 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 200)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), Array(1...200), "gap-free exactly-once")
        XCTAssertGreaterThan(connector.connectCount, 3, "chaos must actually force reconnects")
        await engine.endSync()
    }

    /// Regression for endSync() stranding waitUntilReady() callers: previously
    /// endSync() never resumed readyWaiters, so a caller blocked in
    /// waitUntilReady() while the engine was still trying (and failing) to
    /// connect would hang forever. Races the waiter against a generous
    /// timeout so a regression fails the test instead of hanging the suite.
    func testEndSyncFailsReadyWaitersInsteadOfHanging() async throws {
        let connector = FakeConnector([])
        connector.connectError = JournalConnectionError.socketClosed
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector, backoffBaseSeconds: 0.001)
        await engine.beginSync()
        let waiter = Task { try await engine.waitUntilReady() }
        // Give the run loop a moment to actually be mid-connect/backoff
        // before we tear it down.
        try await Task.sleep(for: .milliseconds(20))
        await engine.endSync()

        enum RaceResult { case waiterThrew(Error), waiterSucceeded, timedOut }
        let result = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
            group.addTask {
                do {
                    try await waiter.value
                    return .waiterSucceeded
                } catch {
                    return .waiterThrew(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .timedOut
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch result {
        case .waiterThrew(let error):
            XCTAssertEqual(error as? JournalSyncError, .offline)
        case .waiterSucceeded:
            XCTFail("waitUntilReady() should have thrown after endSync(), not resumed successfully")
        case .timedOut:
            XCTFail("waitUntilReady() hung after endSync() (regression on Finding 1)")
        }
    }

    /// Regression for isRunning staying true after an auth-rejected start:
    /// runLoop() used to return from the authRejected catch without clearing
    /// runTask, so isRunning stayed true forever.
    func testIsRunningFalseAfterAuthRejected() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"error","code":"auth"}"#)
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()

        var attempts = 0
        while await engine.isRunning, attempts < 200 {
            try await Task.sleep(for: .milliseconds(10))
            attempts += 1
        }
        let isRunning = await engine.isRunning
        XCTAssertFalse(isRunning, "isRunning should be false once the run loop has exited after auth rejection")
    }

    /// waitUntilReady() on an engine that was never started must throw
    /// immediately rather than park the caller forever (there is no run loop
    /// left to ever resume it).
    func testWaitUntilReadyOnNeverStartedEngineThrows() async throws {
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([]))
        do {
            try await engine.waitUntilReady()
            XCTFail("expected waitUntilReady() to throw on a never-started engine")
        } catch {
            XCTAssertEqual(error as? JournalSyncError, .offline)
        }
    }

    /// Regression: waitUntilReady() called AFTER endSync() must throw right
    /// away instead of parking a fresh continuation that nothing will ever
    /// resume. Races against a generous timeout so a regression fails the
    /// test instead of hanging the suite.
    func testWaitUntilReadyAfterEndSyncThrowsInsteadOfHanging() async throws {
        let connector = FakeConnector([])
        connector.connectError = JournalConnectionError.socketClosed
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector, backoffBaseSeconds: 0.001)
        await engine.beginSync()
        try await Task.sleep(for: .milliseconds(30))
        await engine.endSync()

        enum RaceResult { case waiterThrew(Error), waiterSucceeded, timedOut }
        let result = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
            group.addTask {
                do {
                    try await engine.waitUntilReady()
                    return .waiterSucceeded
                } catch {
                    return .waiterThrew(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .timedOut
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }

        switch result {
        case .waiterThrew(let error):
            XCTAssertEqual(error as? JournalSyncError, .offline)
        case .waiterSucceeded:
            XCTFail("waitUntilReady() should have thrown on a stopped engine, not resumed successfully")
        case .timedOut:
            XCTFail("waitUntilReady() hung after endSync() (regression on stopped-engine guard)")
        }
    }

    /// The server's replay-gap valve (spec: src/ws.js snapshot_required):
    /// too large a gap between the client's cursor and the head seq gets a
    /// `snapshot_required` control frame instead of a replay, and the socket
    /// is closed right after. The engine must wipe its mirror and cold-start
    /// from GET /snapshot on the next connect.
    func testSnapshotRequiredWipesMirrorAndColdStarts() async throws {
        let snapshotJSON = #"""
            {"conversations":[{"id":"c9","title":"fresh","session_state":"running","last_seq":400,"unread_count":0,"snippet":"s","created_at":0}],"seq":400}
            """#
        SnapshotRequiredStubURLProtocol.snapshotBody = snapshotJSON
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SnapshotRequiredStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://x")!,
                             urlSession: URLSession(configuration: config))

        // Seed a store with cursor 5 and one convo ("c1") carrying events —
        // this is the mirror that must get wiped.
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        for seq: Int64 in 1...5 {
            _ = try store.applyJournal(JournalEvent(
                seq: seq, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
                payloadData: Data(#"{"body":"m\#(seq)"}"#.utf8)))
        }
        XCTAssertEqual(store.cursor, 5)

        let socket1 = FakeWebSocketConnection()
        socket1.serve(helloOK(500))
        socket1.serve(#"{"kind":"control","op":"snapshot_required"}"#)
        // Mirror the real server: it closes right after snapshot_required.
        // Deferred so `sendText(hello)` (done during establish, right after
        // beginSync) isn't rejected by an already-closed socket — it must
        // only close once the queued frames above have been drained.
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            socket1.closeFromServer()
        }
        let socket2 = FakeWebSocketConnection()
        socket2.serve(helloOK(400))
        let connector = FakeConnector([socket1, socket2])

        let engine = JournalSyncEngine(api: api, store: store, connector: connector,
                                       token: "t", ownSender: "user:dan", search: nil,
                                       backoffBaseSeconds: 0.001)
        await engine.beginSync()

        for _ in 0..<500 where store.cursor != 400 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.cursor, 400)
        let conversations = try store.conversations()
        XCTAssertFalse(conversations.contains { $0.id == "c1" }, "old conversation must be wiped")
        XCTAssertTrue(conversations.contains { $0.id == "c9" }, "cold-start snapshot's conversation must be present")
        XCTAssertTrue(try store.events(convoID: "c1").isEmpty, "old events must be wiped")

        let hello = try XCTUnwrap(socket2.sent.first.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        })
        XCTAssertEqual(hello["cursor"] as? Int64, 400, "reconnect after cold-start must carry the fresh cursor")

        await engine.endSync()
    }
}

/// Local stub for the snapshot_required engine test — deliberately separate
/// from JournalAPITests' StubURLProtocol to avoid cross-file coupling.
/// Always answers GET /snapshot with `snapshotBody` (the engine calls
/// /snapshot both from the cold-start path and from refreshSummaries() on
/// every connect; the same canned response is fine for both).
final class SnapshotRequiredStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var snapshotBody: String = ""

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.snapshotBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

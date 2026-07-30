import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// Offline outbox behaviour: `sendMessage` queues instead of throwing when
/// offline, queued rows flush FIFO with their original `local_id` on
/// (re)connect (server-side idem dedup makes resends safe), and delivery
/// is confirmed — and the row deleted — by the own-text journal frame.
final class JournalSyncEngineOutboxTests: XCTestCase {
    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func ownTextLine(_ seq: Int64, convo: String = "c1", body: String) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"user:dan","type":"text","payload":{"body":"\#(body)"}}"#
    }

    private func makeEngine(
        store: JournalStore, connector: any WebSocketConnecting
    ) -> JournalSyncEngine {
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        return JournalSyncEngine(api: api, store: store, connector: connector,
                                 token: "t", ownSender: "user:dan", search: nil,
                                 backoffBaseSeconds: 0.01)
    }

    private func seededStore() throws -> JournalStore {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0)], headSeq: 0)
        return store
    }

    /// Decoded `op: send` frames a fake socket captured, in order.
    private func sentSendOps(_ socket: FakeWebSocketConnection) -> [[String: Any]] {
        socket.sent.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["op"] as? String == "send" }
    }

    private func waitFor(_ condition: @autoclosure () -> Bool) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSendMessageOfflineQueuesWithoutThrowing() async throws {
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([]))
        // Engine never started: no connection at all.
        try await engine.sendMessage(convoID: "c1", body: "hello", localID: "L1")
        let pending = try store.outboxPending()
        XCTAssertEqual(pending.map(\.localID), ["L1"])
        XCTAssertEqual(pending.first?.attempts, 0, "no connection — never attempted")
    }

    func testSendMessageOnlineSendsWithLocalIDAndKeepsRowUntilConfirmed() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await engine.sendMessage(convoID: "c1", body: "hello", localID: "L1")
        await waitFor(!self.sentSendOps(socket).isEmpty)
        let sends = sentSendOps(socket)
        XCTAssertEqual(sends.count, 1)
        XCTAssertEqual(sends.first?["local_id"] as? String, "L1")
        XCTAssertEqual((sends.first?["payload"] as? [String: Any])?["body"] as? String, "hello")
        // Row survives the socket write — only the journal frame confirms.
        XCTAssertEqual(try store.outboxPending().map(\.localID), ["L1"])
        XCTAssertEqual(try store.outboxPending().first?.attempts, 1)
        await engine.endSync()
    }

    func testConnectFlushesPreexistingQueueFIFO() async throws {
        let store = try seededStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "first",
                               now: Date(timeIntervalSince1970: 1))
        try store.outboxInsert(localID: "B", convoID: "c1", body: "second",
                               now: Date(timeIntervalSince1970: 2))
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        await waitFor(self.sentSendOps(socket).count >= 2)
        XCTAssertEqual(sentSendOps(socket).map { $0["local_id"] as? String }, ["A", "B"])
        await engine.endSync()
    }

    func testOwnTextFrameDeletesConfirmedRow() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await engine.sendMessage(convoID: "c1", body: "hello", localID: "L1")
        await waitFor(!self.sentSendOps(socket).isEmpty)
        // Server journals the send and broadcasts it back.
        socket.serve(ownTextLine(1, body: "hello"))
        await waitFor((try? store.outboxPending().isEmpty) == true)
        XCTAssertTrue(try store.outboxPending().isEmpty, "journal frame is the delivery confirmation")
        await engine.endSync()
    }

    func testOtherSendersFrameDoesNotDeleteQueuedRow() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await engine.sendMessage(convoID: "c1", body: "hello", localID: "L1")
        await waitFor(!self.sentSendOps(socket).isEmpty)
        socket.serve(#"{"kind":"journal","seq":1,"convo_id":"c1","ts":1000,"sender":"agent:a","type":"text","payload":{"body":"hello"}}"#)
        // Give the frame time to apply, then confirm the row survived.
        await waitFor((try? store.events(convoID: "c1").count) == 1)
        XCTAssertEqual(try store.outboxPending().map(\.localID), ["L1"])
        await engine.endSync()
    }

    func testSocketDeathMidQueueResendsSameLocalIDOnReconnect() async throws {
        let store = try seededStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "first", now: Date())
        let first = FakeWebSocketConnection()
        first.serve(helloOK(0))
        let second = FakeWebSocketConnection()
        second.serve(helloOK(0))
        let engine = makeEngine(store: store, connector: FakeConnector([first, second]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        await waitFor(!self.sentSendOps(first).isEmpty)
        XCTAssertEqual(sentSendOps(first).first?["local_id"] as? String, "A")
        // No journal confirmation arrives; the socket dies.
        first.closeFromServer()
        await waitFor(self.sentSendOps(second).count >= 1)
        // Reconnect resends the unconfirmed row with the SAME local_id —
        // the server's idem key dedups if the first copy actually landed.
        XCTAssertEqual(sentSendOps(second).first?["local_id"] as? String, "A")
        await engine.endSync()
    }

    func testRetryOutboxItemRequeuesFailedRowAndFlushes() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        try store.outboxInsert(localID: "F", convoID: "c1", body: "stuck", now: Date())
        try store.outboxMarkFailed(localID: "F", error: "rejected")
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        // Failed rows are excluded from the automatic connect flush.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(sentSendOps(socket).isEmpty)
        await engine.retryOutboxItem(localID: "F")
        await waitFor(!self.sentSendOps(socket).isEmpty)
        XCTAssertEqual(sentSendOps(socket).first?["local_id"] as? String, "F")
        await engine.endSync()
    }

    func testServerRejectionMarksOldestUnconfirmedSendFailed() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([socket]))
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await engine.sendMessage(convoID: "c1", body: "bad one", localID: "R1")
        await waitFor(!self.sentSendOps(socket).isEmpty)
        // The server rejects the op — validation errors can never succeed
        // on retry, so the row must surface as failed instead of silently
        // re-flushing on every reconnect forever.
        socket.serve(#"{"kind":"control","op":"error","code":"bad_request","ref":"send","detail":"nope"}"#)
        await waitFor((try? store.outboxPending().isEmpty) == true)
        let rows = try store.outboxRows(convoID: "c1")
        XCTAssertEqual(rows.map(\.state), [.failed])
        XCTAssertEqual(rows.first?.lastError, "nope")
        await engine.endSync()
    }

    func testApplyJournalDeletesOutboxRowAtomically() throws {
        // Delivery-confirmed deletion lives INSIDE applyJournal's
        // transaction (store-level, no engine involved) so the confirming
        // row and the outbox delete commit together.
        let store = try seededStore()
        try store.outboxInsert(localID: "A", convoID: "c1", body: "hello", now: Date())
        try store.outboxMarkAttempt(localID: "A")
        let own = JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "user:dan", type: "text",
            payloadData: Data(#"{"body":"hello"}"#.utf8))
        XCTAssertTrue(try store.applyJournal(own))
        XCTAssertTrue(try store.outboxRows(convoID: "c1").isEmpty)
    }

    func testReplayedDuplicateFrameDoesNotDeleteOutboxRow() throws {
        // applyJournal's outbox deletion sits BEHIND the seq > cursor
        // guard: a replayed/duplicate own-text frame is a no-op and must
        // not retire a live queued row (post-wipe cold start jumps the
        // cursor to /snapshot's headSeq, so history is never re-applied
        // through applyJournal either — pagination uses insertHistory,
        // which never touches the outbox).
        let store = try seededStore()
        let own = JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "user:dan", type: "text",
            payloadData: Data(#"{"body":"dup"}"#.utf8))
        XCTAssertTrue(try store.applyJournal(own))     // cursor → 1
        try store.outboxInsert(localID: "Q", convoID: "c1", body: "dup", now: Date())
        try store.outboxMarkAttempt(localID: "Q")
        XCTAssertFalse(try store.applyJournal(own), "duplicate frame is a no-op")
        XCTAssertEqual(try store.outboxRows(convoID: "c1").map(\.localID), ["Q"],
                       "a replayed frame must not retire a live queued send")
    }

    func testDiscardOutboxItemDeletesRow() async throws {
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: FakeConnector([]))
        try await engine.sendMessage(convoID: "c1", body: "oops", localID: "D1")
        await engine.discardOutboxItem(localID: "D1")
        XCTAssertTrue(try store.outboxRows(convoID: "c1").isEmpty)
    }
}

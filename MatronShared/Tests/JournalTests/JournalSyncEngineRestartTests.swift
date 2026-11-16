import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// Hosts that stop and start sync as windows come and go (the Mac app) call
/// `endSync()` and `beginSync()` back to back. The stopped run loop can still
/// be mid-handshake or mid-replay when the next one starts, and must not
/// close the new socket or overwrite the new state.
final class JournalSyncEngineRestartTests: XCTestCase {
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

    private func makeEngine(store: JournalStore, connector: any WebSocketConnecting) -> JournalSyncEngine {
        JournalSyncEngine(api: JournalAPI(serverURL: URL(string: "https://x")!), store: store,
                          connector: connector, token: "t", ownSender: "user:alice", search: nil,
                          backoffBaseSeconds: 0.01)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Waits (bounded) until the engine reports `.catchingUp`, so a test that
    /// stops it "during catch-up" really does.
    private func waitForCatchingUp(_ engine: JournalSyncEngine, timeout: Duration = .seconds(2)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await state in engine.stateStream() {
                    if case .catchingUp = state { return true }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let reached = await group.next() ?? false
            group.cancelAll()
            return reached
        }
    }

    /// `endSync()` lands while the hello is out. The handshake cannot be
    /// cancelled, so the loop only learns it was stopped when the hello
    /// returns: it must drop that socket instead of publishing it.
    func testStopDuringHandshakeDropsTheSocketWhenTheHelloReturns() async throws {
        let socket = FakeWebSocketConnection()
        let connector = FakeConnector([socket])
        let engine = makeEngine(store: try seededStore(), connector: connector)
        await engine.beginSync()
        await waitUntil(!socket.sent.isEmpty)
        XCTAssertFalse(socket.sent.isEmpty, "the hello went out")

        await engine.endSync()
        socket.serve(helloOK(0))

        await waitUntil(socket.isClosed)
        XCTAssertTrue(socket.isClosed, "a socket accepted after the stop is closed, not published")
        let running = await engine.isRunning
        XCTAssertFalse(running)
        let caughtUp = await engine.isConnectedAndCaughtUp
        XCTAssertFalse(caughtUp)
    }

    /// The stopped loop's socket is gone and the new loop's is untouched:
    /// no spurious close, no reconnect, no state flip.
    func testImmediateRestartLeavesTheNewSocketAlone() async throws {
        let first = FakeWebSocketConnection()
        first.serve(helloOK(0))
        let second = FakeWebSocketConnection()
        second.serve(helloOK(1))
        second.serve(journalLine(1))
        let connector = FakeConnector([first, second])
        let store = try seededStore()
        let engine = makeEngine(store: store, connector: connector)

        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(connector.connectCount, 1)

        await engine.endSync()
        await engine.beginSync()
        try await engine.waitUntilReady()

        XCTAssertTrue(first.isClosed, "endSync closes the old socket")
        XCTAssertFalse(second.isClosed, "the old loop must not close the new socket")
        // Give a wrongly surviving old loop time to act.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(second.isClosed)
        XCTAssertEqual(connector.connectCount, 2, "no second reconnect")
        let caughtUp = await engine.isConnectedAndCaughtUp
        XCTAssertTrue(caughtUp, "the old loop must not flip the state")
        XCTAssertEqual(store.cursor, 1)
        await engine.endSync()
    }

    /// A restart while a replay is still arriving: the new loop's state is
    /// the only one that counts.
    func testRestartDuringCatchUpEndsOnTheNewLoopsState() async throws {
        let first = FakeWebSocketConnection()
        first.serve(helloOK(5)) // behind the head: catching up
        let second = FakeWebSocketConnection()
        second.serve(helloOK(0))
        let connector = FakeConnector([first, second])
        let engine = makeEngine(store: try seededStore(), connector: connector)

        await engine.beginSync()
        await waitUntil(connector.connectCount == 1 && !first.sent.isEmpty)
        let catchingUp = await waitForCatchingUp(engine)
        XCTAssertTrue(catchingUp, "the first loop is mid catch-up when it is stopped")
        await engine.endSync()
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(second.isClosed)
        let caughtUp = await engine.isConnectedAndCaughtUp
        XCTAssertTrue(caughtUp)
        await engine.endSync()
    }

    /// A path callback that was in flight when the monitor was cancelled (or
    /// before sync began) must not leave the engine waiting for a network.
    func testStalePathCallbackDoesNotMarkTheEngineAsWaitingForNetwork() async throws {
        let engine = makeEngine(store: try seededStore(), connector: FakeConnector([]))
        let before = await engine.isWaitingForNetwork
        XCTAssertFalse(before)
        await engine.handlePathUpdate(satisfied: false, signature: "unsatisfied|")
        let after = await engine.isWaitingForNetwork
        XCTAssertFalse(after, "no monitor is running, so the callback is stale")
    }

    private func sendOps(_ socket: FakeWebSocketConnection) -> [String] {
        socket.sent.filter {
            ((try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any])?["op"] as? String == "send"
        }
    }

    /// The race the generation token exists for: the old loop is past its
    /// hello, suspended in a post-hello send, while a restart publishes the
    /// new socket. When the old send finally returns, nothing it does may
    /// reach the new loop's socket, state or send bookkeeping.
    func testOldLoopSuspendedInAPostHelloSendCannotDisturbTheNewLoop() async throws {
        let first = FakeWebSocketConnection()
        first.holdSends(after: 1) // the hello goes out; the next send waits
        first.serve(helloOK(5)) // behind the head: the old loop would report catching up
        let second = FakeWebSocketConnection()
        second.serve(helloOK(0))
        let connector = FakeConnector([first, second])
        let engine = makeEngine(store: try seededStore(), connector: connector)

        await engine.beginSync()
        await waitUntil(first.heldCount == 1)
        XCTAssertEqual(first.heldCount, 1, "the old loop is suspended in a post-hello send")

        // endSync waits for the old loop, which cannot finish yet.
        let stopping = Task { await engine.endSync() }
        let deadline = Date().addingTimeInterval(2)
        while await engine.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await engine.beginSync()
        try await engine.waitUntilReady()
        try await engine.sendMessage(convoID: "c1", body: "x", localID: "L1")
        await waitUntil(sendOps(second).count == 1)
        XCTAssertEqual(sendOps(second).count, 1)

        first.releaseHeldSends()
        await stopping.value
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(second.isClosed, "the old loop must not close the new socket")
        let caughtUp = await engine.isConnectedAndCaughtUp
        XCTAssertTrue(caughtUp, "the old loop must not flip the state to catching up")
        XCTAssertEqual(sendOps(second).count, 1, "the old loop must not reset the send bookkeeping and resend")
        XCTAssertEqual(connector.connectCount, 2)
        await engine.endSync()
    }
}

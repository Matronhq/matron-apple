import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// Live frames nobody is looking at are written together, at most
/// `JournalSyncEngine.liveFlushDelay` after the first of them arrives.
final class JournalSyncEngineLiveBatchTests: XCTestCase {
    private func line(_ seq: Int64, convo: String = "c1", sender: String = "agent:a", type: String = "text") -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"\#(sender)","type":"\#(type)","payload":{"body":"m\#(seq)"}}"#
    }

    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func seededStore() throws -> JournalStore {
        let store = try makeTestStore(.queue)
        try store.applyColdSnapshot(["c1", "c2"].map {
            ConvoSummaryDTO(id: $0, title: $0, sessionState: "running", lastSeq: 0, snippet: "", createdAt: 0)
        }, headSeq: 1)
        return store
    }

    private func engine(store: JournalStore, socket: FakeWebSocketConnection) async throws -> JournalSyncEngine {
        socket.serve(helloOK(1))
        let engine = JournalSyncEngine(api: JournalAPI(serverURL: URL(string: "https://x")!), store: store,
                                       connector: FakeConnector([socket]), token: "t", ownSender: "user:alice",
                                       search: nil, backoffBaseSeconds: 0.01)
        await engine.beginSync()
        try await engine.waitUntilReady()
        return engine
    }

    private func acks(_ socket: FakeWebSocketConnection) -> [Int64] {
        socket.sent.compactMap { text -> Int64? in
            guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  obj["op"] as? String == "ack" else { return nil }
            return (obj["cursor"] as? NSNumber)?.int64Value
        }
    }

    private func until(_ what: String, timeout: Duration = .seconds(3), _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if (try? condition()) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testFramesNobodyIsLookingAtAreWrittenTogetherWithinTheDelay() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore()
        let engine = try await engine(store: store, socket: socket)
        let acksBefore = acks(socket).count
        socket.serve(line(2))
        socket.serve(line(3, convo: "c2"))
        socket.serve(line(4))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.cursor, 1, "held for the group")
        try await until("the group lands") { store.cursor == 4 }
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [2, 4])
        XCTAssertEqual(acks(socket).dropFirst(acksBefore), [4], "one ack for the group")
        await engine.endSync()
    }

    func testAFrameInAnOpenConversationIsWrittenAtOnceAfterWhatWasWaiting() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore()
        let engine = try await engine(store: store, socket: socket)
        await engine.registerViewer(UUID(), convoID: "c2")
        socket.serve(line(2))
        socket.serve(line(3, convo: "c2"))
        try await until("the open conversation's frame") { store.cursor == 3 }
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [2], "the waiting frame went first")
        XCTAssertEqual(try store.events(convoID: "c2").map(\.seq), [3])
        await engine.endSync()
    }

    func testThisDevicesOwnFrameIsWrittenAtOnce() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore()
        let engine = try await engine(store: store, socket: socket)
        socket.serve(line(2, sender: "user:alice"))
        try await until("the echo", timeout: .milliseconds(500)) { store.cursor == 2 }
        await engine.endSync()
    }

    func testAFullGroupIsWrittenWithoutWaiting() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore()
        let engine = try await engine(store: store, socket: socket)
        let last = Int64(1 + JournalSyncEngine.liveBatchMax)
        for seq in 2...last { socket.serve(line(seq)) }
        try await until("the full group", timeout: .milliseconds(800)) { store.cursor == last }
        await engine.endSync()
    }

    func testAClosedSocketStillWritesWhatWasWaiting() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore()
        let engine = try await engine(store: store, socket: socket)
        socket.serve(line(2))
        socket.serve(line(3))
        try await Task.sleep(for: .milliseconds(100))
        socket.closeFromServer()
        try await until("the teardown write", timeout: .milliseconds(800)) { store.cursor == 3 }
        await engine.endSync()
    }
}

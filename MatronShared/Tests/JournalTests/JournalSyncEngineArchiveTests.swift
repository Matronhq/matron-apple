import XCTest
import Foundation
@testable import MatronJournal

/// The engine's archive wiring: `archive_since` in the hello, the
/// `hello_ok.archive` delta applied before the replay, and live frames.
final class JournalSyncEngineArchiveTests: XCTestCase {
    private func seededStore() throws -> JournalStore {
        let store = try makeTestStore(.queue)
        try store.applyColdSnapshot(["c1", "c2"].map {
            ConvoSummaryDTO(id: $0, title: $0, sessionState: "done", lastSeq: 0, snippet: "", createdAt: 0)
        }, headSeq: 0)
        return store
    }

    private func makeEngine(_ store: JournalStore, _ socket: FakeWebSocketConnection) -> JournalSyncEngine {
        JournalSyncEngine(api: JournalAPI(serverURL: URL(string: "https://x")!), store: store,
                          connector: FakeConnector([socket]), token: "t", ownSender: "user:alice",
                          search: nil, backoffBaseSeconds: 0.01)
    }

    private func hello(_ socket: FakeWebSocketConnection) throws -> [String: Any] {
        try XCTUnwrap(socket.sent.first.flatMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        })
    }

    func testHelloAsksForTheArchiveAndAppliesTheAnswerAndFrames() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0,"archive":{"changes":[{"convo_id":"c1","archived_at":100,"auto":true}],"at":150}}"#)
        let store = try seededStore()
        let engine = makeEngine(store, socket)
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(try hello(socket)["archive_since"] as? Int64, 0, "no cursor yet: the whole set")
        await engine.archive.waitUntilIdle()
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["c1"])
        XCTAssertEqual(try store.archiveSince(), 150)

        socket.serve(#"{"kind":"archive","changes":[{"convo_id":"c1","archived_at":null},{"convo_id":"c2","archived_at":200}],"at":250}"#)
        for _ in 0..<200 where (try? store.archiveSince()) != 250 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["c2"])
        XCTAssertEqual(try store.conversations().map(\.id), ["c1"])
        await engine.endSync()
    }

    func testAStoredCursorIsSentInTheHello() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0,"archive":{"changes":[],"at":80}}"#)
        let store = try seededStore()
        try store.setArchiveSince(70)
        let engine = makeEngine(store, socket)
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(try hello(socket)["archive_since"] as? Int64, 70)
        XCTAssertEqual(try store.archiveSince(), 80)
        await engine.endSync()
    }

    func testAnOlderJournalLeavesTheArchiveLocal() async throws {
        let socket = FakeWebSocketConnection()
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0}"#)
        let store = try seededStore()
        let engine = makeEngine(store, socket)
        await engine.beginSync()
        try await engine.waitUntilReady()
        let syncs = await engine.archive.syncsWithJournal
        XCTAssertFalse(syncs)
        await engine.archive.setArchived(["c2"], archived: true)
        XCTAssertEqual(try store.archivedConversations().map(\.id), ["c2"])
        XCTAssertNil(try store.archiveSince())
        await engine.endSync()
    }
}

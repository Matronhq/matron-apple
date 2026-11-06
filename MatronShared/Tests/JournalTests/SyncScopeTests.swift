import XCTest
import Foundation
import MatronSearch
@testable import MatronJournal

/// The `forYou` sync scope (protocol "Sync scope"): the wire, the mirror's
/// record of how far each conversation is complete, and the engine.
final class SyncScopeWireTests: XCTestCase {
    func testHelloNamesTheScopeOnlyWhenGiven() throws {
        func hello(_ op: ClientOp) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(op.encoded().utf8)) as? [String: Any])
        }
        XCTAssertNil(try hello(.hello(token: "t", cursor: 1))["sync"])
        XCTAssertEqual(try hello(.hello(token: "t", cursor: 1, sync: .forYou))["sync"] as? String, "for_you")
        XCTAssertEqual(try hello(.hello(token: "t", cursor: 1, sync: .everything))["sync"] as? String, "everything")
    }

    func testHelloOKCarriesTheScopeItGot() {
        guard case let .helloOK(_, _, _, sync)? = ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":3,"sync":"for_you"}"#) else {
            return XCTFail("expected hello_ok")
        }
        XCTAssertEqual(sync, .forYou)
        guard case let .helloOK(_, _, _, older)? = ServerFrame.decode(#"{"kind":"control","op":"hello_ok","seq":3}"#) else {
            return XCTFail("expected hello_ok")
        }
        XCTAssertNil(older, "a journal that predates sync scopes says nothing")
    }

    func testCursorFrame() {
        XCTAssertEqual(ServerFrame.decode(#"{"kind":"control","op":"cursor","seq":812}"#), .cursor(seq: 812))
        XCTAssertNil(ServerFrame.decode(#"{"kind":"control","op":"cursor"}"#))
    }

    func testTheSettingDefaultsToEverything() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "sync-scope-\(UUID().uuidString)"))
        XCTAssertEqual(SyncScope.stored(in: defaults), .everything)
        SyncScope.forYou.store(in: defaults)
        XCTAssertEqual(SyncScope.stored(in: defaults), .forYou)
        defaults.set("junk", forKey: SyncScope.defaultsKey)
        XCTAssertEqual(SyncScope.stored(in: defaults), .everything)
    }
}

final class SyncScopeStoreTests: XCTestCase {
    private func event(_ seq: Int64, _ convo: String = "c1", type: String = "text") -> JournalEvent {
        JournalEvent(seq: seq, convoID: convo, ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:box-a",
                     type: type, payloadData: Data(#"{"body":"m\#(seq)"}"#.utf8))
    }

    private func seededStore(cursor: Int64 = 0) throws -> JournalStore {
        let store = try makeTestStore(.queue)
        try store.applyColdSnapshot(["c1", "c2"].map {
            ConvoSummaryDTO(id: $0, title: $0, sessionState: "done", lastSeq: 0, snippet: "", createdAt: 0)
        }, headSeq: cursor)
        return store
    }

    func testAdvanceCursorNeverMovesBack() throws {
        let store = try seededStore(cursor: 10)
        try store.advanceCursor(to: 40)
        XCTAssertEqual(store.cursor, 40)
        try store.advanceCursor(to: 20)
        XCTAssertEqual(store.cursor, 40)
    }

    func testTheSwitchPointIsKeptFromTheFirstSwitch() throws {
        let store = try seededStore(cursor: 10)
        XCTAssertNil(try store.forYouSince())
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 0)
        try store.markForYouStart()
        try store.advanceCursor(to: 50)
        try store.markForYouStart()
        XCTAssertEqual(try store.forYouSince(), 10)
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 10, "every conversation is complete up to the switch")
        try store.setSyncedSeq(30, convoID: "c1")
        try store.setSyncedSeq(20, convoID: "c1")
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 30)
        XCTAssertEqual(try store.syncedSeq(convoID: "c2"), 10)
        try store.wipe()
        XCTAssertNil(try store.forYouSince())
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 0)
    }

    func testATailThatReachesTheMirrorKeepsItsOlderEvents() throws {
        let store = try seededStore()
        try store.insertHistory([event(1), event(2), event(3, "c2")])
        let dropped = try store.insertConversationTail([event(2), event(5), event(9)], convoID: "c1", reachesSyncedSeq: true)
        XCTAssertEqual(dropped, [])
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [1, 2, 5, 9])
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 9)
    }

    func testATailBehindAGapDropsTheStrandedEventsOfThatConversationOnly() throws {
        let store = try seededStore()
        try store.insertHistory([event(1), event(2), event(3, "c2")])
        let dropped = try store.insertConversationTail([event(20), event(21)], convoID: "c1", reachesSyncedSeq: false)
        XCTAssertEqual(dropped, [1, 2])
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [20, 21])
        XCTAssertEqual(try store.events(convoID: "c2").map(\.seq), [3])
        XCTAssertEqual(try store.minSeq(convoID: "c1"), 20, "scrolling back pages below the new oldest event")
    }

    func testARefreshAdoptsTheJournalsUnreadCountsOnlyWhenAsked() throws {
        let store = try seededStore()
        let summary = ConvoSummaryDTO(id: "c1", title: "c1", sessionState: "done", lastSeq: 5, snippet: "hi",
                                      createdAt: 0, unreadCount: 4)
        try store.refreshSummaries([summary])
        XCTAssertEqual(try store.conversation(id: "c1")?.unreadCount, 0)
        try store.refreshSummaries([summary], adoptUnread: true)
        XCTAssertEqual(try store.conversation(id: "c1")?.unreadCount, 4)
        let fresh = ConvoSummaryDTO(id: "c3", title: "c3", sessionState: "done", lastSeq: 6, snippet: "",
                                    createdAt: 0, unreadCount: 2)
        try store.refreshSummaries([fresh], adoptUnread: true)
        XCTAssertEqual(try store.conversation(id: "c3")?.unreadCount, 2)
    }
}

/// Serves `GET /convo/:id/messages` pages from `events`, newest first, the
/// way the journal pages them, and records each request.
final class MessagesStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var events: [[String: Any]] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    /// How many `/messages` requests answer 500 before the stub serves pages.
    nonisolated(unsafe) static var failuresLeft = 0
    /// The conversation fetches only; every connect also asks for `/snapshot`.
    static var messageRequests: [URLRequest] { requests.filter { $0.url?.path.hasSuffix("/messages") == true } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let limit = items.first { $0.name == "limit" }?.value.flatMap(Int.init) ?? 50
        let before = items.first { $0.name == "before_seq" }?.value.flatMap(Int64.init)
        guard request.url?.path.hasSuffix("/messages") == true else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if Self.failuresLeft > 0 {
            Self.failuresLeft -= 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{}".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let page = Self.events
            .filter { before == nil || (($0["seq"] as? Int64) ?? 0) < before! }
            .suffix(limit)
        let body = try! JSONSerialization.data(withJSONObject: ["events": Array(page)])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SyncScopeEngineTests: XCTestCase {
    override func setUp() {
        MessagesStubURLProtocol.events = []
        MessagesStubURLProtocol.requests = []
        MessagesStubURLProtocol.failuresLeft = 0
    }

    private func stubbedAPI() -> JournalAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MessagesStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private func seededStore(cursor: Int64) throws -> JournalStore {
        let store = try makeTestStore(.queue)
        try store.applyColdSnapshot(["c1", "coord"].map {
            ConvoSummaryDTO(id: $0, title: $0, sessionState: "done", lastSeq: 0, snippet: "", createdAt: 0)
        }, headSeq: cursor)
        return store
    }

    private func sentJSON(_ socket: FakeWebSocketConnection) -> [[String: Any]] {
        socket.sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    private func until(_ what: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<300 {
            if (try? condition()) == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func frame(_ seq: Int64, _ convo: String, _ type: String = "text") -> [String: Any] {
        ["kind": "journal", "seq": seq, "convo_id": convo, "ts": seq * 1000, "sender": "agent:box-a",
         "type": type, "payload": ["body": "m\(seq)"]]
    }

    private func serve(_ socket: FakeWebSocketConnection, _ obj: [String: Any]) throws {
        socket.serve(String(decoding: try JSONSerialization.data(withJSONObject: obj), as: UTF8.self))
    }

    func testAForYouReplayEndsAtTheHeadTheCursorFrameNames() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        let stats = SyncStatsRecorder(defaults: UserDefaults(suiteName: "stats-\(UUID().uuidString)")!)
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou, stats: stats)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":100,"sync":"for_you"}"#)
        try serve(socket, frame(42, "c1", "item"))
        try serve(socket, frame(57, "coord"))
        socket.serve(#"{"kind":"control","op":"cursor","seq":100}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(sentJSON(socket).first?["sync"] as? String, "for_you")
        XCTAssertEqual(store.cursor, 100)
        XCTAssertEqual(try store.events(convoID: "coord").map(\.seq), [57])
        XCTAssertTrue(sentJSON(socket).contains { $0["op"] as? String == "ack" && $0["cursor"] as? Int64 == 100 })
        XCTAssertEqual(stats.snapshot().today.events, 2)
        XCTAssertEqual(stats.snapshot().today.catchUps, 1)
        await engine.endSync()
    }

    func testOpeningAConversationFetchesWhatItIsMissing() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        try store.insertHistory([JournalEvent(frameObject: frame(5, "c1"))!])
        // The journal has 5 (already here), 30 and 31 for c1.
        MessagesStubURLProtocol.events = [frame(5, "c1"), frame(30, "c1"), frame(31, "c1")]
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":40,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":40}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        await engine.registerViewer(UUID(), convoID: "c1")
        try await until("the fetch") { try store.events(convoID: "c1").map(\.seq) == [5, 30, 31] }
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, 1, "one page reached the stored events")
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 31)
        await engine.endSync()
    }

    func testOnEverythingOpeningAConversationFetchesNothing() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":10}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        await engine.registerViewer(UUID(), convoID: "c1")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, 0)
        XCTAssertEqual(sentJSON(socket).first?["sync"] as? String, "everything",
                       "named, so a device switched back is cleared on the journal")
        await engine.endSync()
    }

    func testAChatOpenedDuringTheReplayIsFetchedOnlyAfterIt() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        MessagesStubURLProtocol.events = [frame(30, "c1")]
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":40,"sync":"for_you"}"#)
        let states = engine.stateStream()
        await engine.beginSync()
        for await state in states { if case .catchingUp = state { break } }
        await engine.registerViewer(UUID(), convoID: "c1")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, 0, "the replay is still running")
        socket.serve(#"{"kind":"control","op":"cursor","seq":40}"#)
        try await until("the fetch") { try store.events(convoID: "c1").map(\.seq) == [30] }
        await engine.endSync()
    }

    func testSwitchingBackToEverythingRebuildsTheMirror() async throws {
        let first = FakeWebSocketConnection()
        let second = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([first, second]),
                                       token: "t", ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        first.serve(#"{"kind":"control","op":"hello_ok","seq":10,"sync":"for_you"}"#)
        first.serve(#"{"kind":"control","op":"cursor","seq":10}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        second.serve(#"{"kind":"control","op":"hello_ok","seq":10,"sync":"everything"}"#)
        await engine.setSyncScope(.everything)
        try await until("the second hello") { !second.sent.isEmpty }
        XCTAssertEqual(sentJSON(second).first?["sync"] as? String, "everything")
        XCTAssertEqual(try store.conversations().map(\.id), [], "rebuilt from the (empty) snapshot")
        await engine.endSync()
    }

    func testAGapLongerThanTheFetchDropsTheStrandedEvents() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        try store.insertHistory([JournalEvent(frameObject: frame(5, "c1"))!])
        MessagesStubURLProtocol.events = [frame(5, "c1")] + (100..<800).map { frame(Int64($0), "c1") }
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":900,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":900}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        await engine.registerViewer(UUID(), convoID: "c1")
        try await until("the fetch") { try store.minSeq(convoID: "c1") == 200 }
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, JournalSyncEngine.conversationMaxPages)
        XCTAssertEqual(try store.events(convoID: "c1").count, 600)
        await engine.endSync()
    }

    func testTheDroppedEventsLeaveTheSearchIndex() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        try store.insertHistory([JournalEvent(frameObject: frame(5, "c1"))!])
        MessagesStubURLProtocol.events = [frame(5, "c1")] + (100..<800).map { frame(Int64($0), "c1") }
        let search = RemovalRecordingSearch()
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: search, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":900,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":900}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        await engine.registerViewer(UUID(), convoID: "c1")
        for _ in 0..<300 where await search.removed.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let removed = await search.removed
        XCTAssertEqual(removed, ["5"])
        await engine.endSync()
    }

    func testAFailedFetchIsRetriedWhileTheChatStaysOpen() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        MessagesStubURLProtocol.events = [frame(30, "c1")]
        MessagesStubURLProtocol.failuresLeft = 2
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":40,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":40}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        await engine.registerViewer(UUID(), convoID: "c1")
        try await until("the third attempt") { try store.events(convoID: "c1").map(\.seq) == [30] }
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, 3)
        await engine.endSync()
    }

    func testAFetchForAClosedChatIsNotRetried() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        MessagesStubURLProtocol.events = [frame(30, "c1")]
        MessagesStubURLProtocol.failuresLeft = 1
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.2,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":40,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":40}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        let token = UUID()
        await engine.registerViewer(token, convoID: "c1")
        try await until("the failed attempt") { MessagesStubURLProtocol.messageRequests.count == 1 }
        await engine.unregisterViewer(token)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(MessagesStubURLProtocol.messageRequests.count, 1)
        await engine.endSync()
    }

    func testClosingAChatRecordsHowFarItIsComplete() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        MessagesStubURLProtocol.events = [frame(30, "c1")]
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":40,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":40}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        let viewer = UUID()
        await engine.registerViewer(viewer, convoID: "c1")
        try await until("the fetch") { try store.syncedSeq(convoID: "c1") == 30 }
        // Live while it is open.
        try serve(socket, frame(45, "c1"))
        try await until("the live frame") { store.cursor == 45 }
        await engine.unregisterViewer(viewer)
        XCTAssertEqual(try store.syncedSeq(convoID: "c1"), 45)
        await engine.endSync()
    }

    func testAMirrorLeftOnForYouIsRebuiltWhenTheAppStartsOnEverything() async throws {
        // Switched back offline, or killed before reconnecting: the setting
        // says everything, the store still carries the forYou marker.
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        try store.markForYouStart()
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":0,"sync":"everything"}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertNil(try store.forYouSince())
        XCTAssertEqual(try store.conversations().map(\.id), [], "rebuilt from the (empty) snapshot")
        await engine.endSync()
    }

    func testStartingOnForYouRecordsTheSwitchPoint() async throws {
        let socket = FakeWebSocketConnection()
        let store = try seededStore(cursor: 10)
        let engine = JournalSyncEngine(api: stubbedAPI(), store: store, connector: FakeConnector([socket]), token: "t",
                                       ownSender: "user:alice", search: nil, backoffBaseSeconds: 0.01,
                                       syncScope: .forYou)
        socket.serve(#"{"kind":"control","op":"hello_ok","seq":10,"sync":"for_you"}"#)
        socket.serve(#"{"kind":"control","op":"cursor","seq":10}"#)
        await engine.beginSync()
        try await engine.waitUntilReady()
        XCTAssertEqual(try store.forYouSince(), 10)
        await engine.endSync()
    }
}

/// Records what the engine retires from the index.
private actor RemovalRecordingSearch: SearchService {
    private(set) var removed: [String] = []
    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {}
    func indexBatch(_ entries: [SearchIndexEntry]) async throws {}
    func remove(eventID: String) async throws { removed.append(eventID) }
    func removeAll(eventIDs: [String]) async throws { removed.append(contentsOf: eventIDs) }
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func wipe() async throws {}
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
    func backfillComplete(roomID: String) async throws -> Bool { false }
    func backfillOldestEventID(roomID: String) async throws -> String? { nil }
    func resetBackfill() async throws {}
    func eventCount(roomID: String) async throws -> Int { 0 }
    func contains(eventID: String) async throws -> Bool { false }
}

import XCTest
import Foundation
import MatronJournal
import MatronModels
import MatronSearch
@testable import MatronChat

final class JournalTimelineServiceTests: XCTestCase {
    // MARK: Fixtures

    private func makeStore(convoID: String = "c1") throws -> JournalStore {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: convoID, title: "", sessionState: "running",
                            lastSeq: 0, snippet: "", createdAt: 0),
        ], headSeq: 0)
        return store
    }

    private func makeEngine(store: JournalStore, connector: any WebSocketConnecting, api: JournalAPI) -> JournalSyncEngine {
        JournalSyncEngine(api: api, store: store, connector: connector,
                          token: "t", ownSender: "user:dan", search: nil,
                          backoffBaseSeconds: 0.01)
    }

    private func makeSession() -> UserSession {
        UserSession(userID: "dan", deviceID: "d1", homeserverURL: URL(string: "https://x")!, accessToken: "t")
    }

    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func journalFrame(seq: Int64, convo: String = "c1", sender: String = "agent:a",
                              type: String = "text", payload: [String: Any]) -> String {
        let obj: [String: Any] = [
            "kind": "journal", "seq": seq, "convo_id": convo, "ts": seq * 1000,
            "sender": sender, "type": type, "payload": payload,
        ]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(decoding: data, as: UTF8.self)
    }

    private func waitUntil(
        timeout: TimeInterval = 3, file: StaticString = #filePath, line: UInt = #line,
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        XCTFail("timed out waiting for condition", file: file, line: line)
    }

    /// Collects every `items()` snapshot into an actor-protected array so the
    /// test can poll `values.last` from a plain `Task.sleep` loop instead of
    /// juggling an `inout` `AsyncIterator` across concurrency domains.
    private actor ItemsCollector {
        private(set) var values: [[TimelineItem]] = []
        func add(_ items: [TimelineItem]) { values.append(items) }
    }

    private func collectItems(_ stream: AsyncThrowingStream<[TimelineItem], Error>) -> (ItemsCollector, Task<Void, Never>) {
        let collector = ItemsCollector()
        let task = Task {
            do {
                for try await items in stream { await collector.add(items) }
            } catch {}
        }
        return (collector, task)
    }

    // MARK: (a) store events surface as mapped items

    func testStoreEventsSurfaceAsMappedItems() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"hello"}"#.utf8)))

        let socket = FakeJournalSocket()
        socket.serve(helloOK(1))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last?.count == 1 }

        let items = await collector.values.last!
        XCTAssertEqual(items.first?.id, "1")
        XCTAssertEqual(items.first?.sendState, .sent)
        if case let .text(body, _) = items.first?.kind {
            XCTAssertEqual(body, "hello")
        } else {
            XCTFail("expected .text kind")
        }

        task.cancel()
        await engine.endSync()
    }

    // MARK: (b) ephemeral overlay inserts + a matching finalize removes it

    func testEphemeralOverlayInsertsAndFinalizeRemoves() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil } // initial empty snapshot

        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m1","replace_text":"thinking…"}"#)
        try await waitUntil { await collector.values.last?.contains { $0.id == "eph:m1" } == true }
        let overlaid = await collector.values.last!
        XCTAssertEqual(overlaid.count, 1)
        if case let .text(body, _) = overlaid.first?.kind {
            XCTAssertEqual(body, "thinking…")
        } else {
            XCTFail("expected streaming .text kind")
        }
        XCTAssertFalse(overlaid.first?.isOwn ?? true)

        // Finalize: a real journal event carrying the same message_ref lands.
        socket.serve(journalFrame(seq: 1, type: "text", payload: ["body": "final answer", "message_ref": "m1"]))
        try await waitUntil {
            guard let last = await collector.values.last else { return false }
            return last.count == 1 && !last.contains { $0.id == "eph:m1" }
        }
        let finalItems = await collector.values.last!
        XCTAssertEqual(finalItems.first?.id, "1")

        task.cancel()
        await engine.endSync()
    }

    // MARK: (b2) activity ephemeral surfaces a trailing indicator row; idle clears it

    func testActivityIndicatorAppearsAndIdleClears() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil }

        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"tool","detail":"Bash"}}"#)
        try await waitUntil { await collector.values.last?.contains { $0.id == "activity" } == true }
        let withIndicator = await collector.values.last!
        guard case let .activityIndicator(label) = withIndicator.first(where: { $0.id == "activity" })?.kind else {
            return XCTFail("expected an activityIndicator row")
        }
        XCTAssertEqual(label, "Running Bash")

        // idle clears the indicator.
        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","activity":{"state":"idle"}}"#)
        try await waitUntil { await collector.values.last?.contains { $0.id == "activity" } == false }

        task.cancel()
        await engine.endSync()
    }

    // MARK: (b3) finalize with no message_ref still retires the overlay by body

    func testFinalizeWithoutMessageRefRetiresOverlayByBody() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil }

        // Stream builds an overlay to the final text.
        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m1","replace_text":"final answer"}"#)
        try await waitUntil { await collector.values.last?.contains { $0.id == "eph:m1" } == true }

        // Finalize lands as a real row whose body matches — but WITHOUT the
        // message_ref in its payload (the bridge omitted it). The body-match
        // fallback must still retire the overlay so it doesn't double-show.
        socket.serve(journalFrame(seq: 1, type: "text", payload: ["body": "final answer"]))
        try await waitUntil {
            guard let last = await collector.values.last else { return false }
            return last.count == 1 && !last.contains { $0.id == "eph:m1" }
        }
        let finalItems = await collector.values.last!
        XCTAssertEqual(finalItems.first?.id, "1")

        task.cancel()
        await engine.endSync()
    }

    // MARK: (c) sendText emits a .sending local echo immediately, op reaches
    // the socket, and the echo reconciles when the own journal row arrives

    func testSendTextEmitsLocalEchoOpReachesSocketAndReconciles() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil }

        try await service.sendText("hi there", inReplyTo: nil)

        try await waitUntil { await collector.values.last?.contains { $0.sendState == .sending && $0.isOwn } == true }
        let echoed = await collector.values.last!
        XCTAssertEqual(echoed.count, 1)
        XCTAssertEqual(echoed.first?.sendState, .sending)
        if case let .text(body, _) = echoed.first?.kind {
            XCTAssertEqual(body, "hi there")
        } else {
            XCTFail("expected echo .text kind")
        }

        try await waitUntil { socket.lastSentObject?["op"] as? String == "send" }
        let sentPayload = socket.lastSentObject
        XCTAssertEqual(sentPayload?["convo_id"] as? String, "c1")
        XCTAssertEqual((sentPayload?["payload"] as? [String: Any])?["body"] as? String, "hi there")

        // The own journal row arrives: the echo must reconcile away, leaving
        // only the real (sent) item.
        socket.serve(journalFrame(seq: 1, sender: "user:dan", type: "text", payload: ["body": "hi there"]))
        try await waitUntil {
            guard let last = await collector.values.last else { return false }
            return last.count == 1 && last.first?.sendState == .sent
        }
        let reconciled = await collector.values.last!
        XCTAssertEqual(reconciled.first?.id, "1")
        XCTAssertTrue(reconciled.first?.isOwn ?? false)

        task.cancel()
        await engine.endSync()
    }

    // MARK: (d) sendText(inReplyTo:) sends a prompt_reply op

    func testSendTextWithReplyToSendsPromptReplyOp() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        try await service.sendText("yes please", inReplyTo: "3")

        try await waitUntil { socket.lastSentObject?["op"] as? String == "prompt_reply" }
        let sent = socket.lastSentObject
        XCTAssertEqual((sent?["target_seq"] as? NSNumber)?.int64Value, 3)
        XCTAssertEqual(sent?["text"] as? String, "yes please")
        XCTAssertTrue(sent?["choice"] is NSNull, "no button choice on a free-text reply")
        XCTAssertEqual(sent?["convo_id"] as? String, "c1")

        await engine.endSync()
    }

    // MARK: (e) markAsRead sends read_marker with the max seq

    func testMarkAsReadSendsReadMarkerWithMaxSeq() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"a"}"#.utf8)))
        try store.applyJournal(JournalEvent(
            seq: 2, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"b"}"#.utf8)))

        let socket = FakeJournalSocket()
        socket.serve(helloOK(2))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        await engine.beginSync()
        try await engine.waitUntilReady()

        try await service.markAsRead()

        try await waitUntil { socket.lastSentObject?["op"] as? String == "read_marker" }
        let sent = socket.lastSentObject
        XCTAssertEqual((sent?["up_to_seq"] as? NSNumber)?.int64Value, 2)
        XCTAssertEqual(sent?["convo_id"] as? String, "c1")

        await engine.endSync()
    }

    // MARK: sendImage / sendFile throw mediaNotSupported

    func testSendImageAndSendFileThrowMediaNotSupported() async throws {
        let store = try makeStore()
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())

        do {
            try await service.sendImage(Data(), filename: "x.png", mimeType: "image/png")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JournalChatError, .mediaNotSupported)
        }

        do {
            try await service.sendFile(Data(), filename: "x.bin", mimeType: "application/octet-stream")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? JournalChatError, .mediaNotSupported)
        }
    }

    // MARK: paginateBackward inserts history + feeds search, returns false on an empty page

    func testPaginateBackwardInsertsHistoryAndIndexesSearch() async throws {
        let store = try makeStore()
        try store.applyJournal(JournalEvent(
            seq: 10, convoID: "c1", ts: Date(), sender: "agent:a", type: "text",
            payloadData: Data(#"{"body":"recent"}"#.utf8)))

        PaginateStubURLProtocol.responses = [
            "/convo/c1/messages": (200, """
                {"events":[{"seq":8,"convo_id":"c1","ts":8000,"sender":"agent:a","type":"text","payload":{"body":"older msg"}}]}
                """),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaginateStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://x")!, urlSession: URLSession(configuration: config))
        let engine = makeEngine(store: store, connector: FakeJournalConnector([]), api: api)
        let search = RecordingSearchService()
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api,
                                             session: makeSession(), search: search)

        let hasMore = try await service.paginateBackward(requestSize: 20)
        XCTAssertTrue(hasMore)
        XCTAssertEqual(try store.events(convoID: "c1").map(\.seq), [8, 10])

        let query = PaginateStubURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("before_seq=10"))
        XCTAssertTrue(query.contains("limit=20"))

        let indexed = await search.indexed
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.body, "older msg")
        XCTAssertEqual(indexed.first?.eventID, "8")
    }

    func testPaginateBackwardReturnsFalseOnEmptyPage() async throws {
        let store = try makeStore()
        PaginateStubURLProtocol.responses = ["/convo/c1/messages": (200, #"{"events":[]}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaginateStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://x")!, urlSession: URLSession(configuration: config))
        let engine = makeEngine(store: store, connector: FakeJournalConnector([]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())

        let hasMore = try await service.paginateBackward(requestSize: 20)
        XCTAssertFalse(hasMore)
        XCTAssertTrue(try store.events(convoID: "c1").isEmpty)
    }

    // MARK: (f) sendText failure flips the local echo to .failed instead of
    // leaving it stuck in .sending forever, and rethrows so the caller
    // (ComposerViewModel) can surface the error and keep the user's text.

    func testSendTextFailureMarksEchoFailed() async throws {
        let store = try makeStore()
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        // No socket at all and `beginSync()` never called: `liveConnection`
        // stays nil, so `sendOp` throws `.offline` synchronously, exactly
        // like calling send while genuinely offline.
        let engine = makeEngine(store: store, connector: FakeJournalConnector([]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil } // initial empty snapshot

        do {
            try await service.sendText("hi there", inReplyTo: nil)
            XCTFail("expected sendText to rethrow the offline send failure")
        } catch {
            XCTAssertEqual(error as? JournalSyncError, .offline)
        }

        try await waitUntil {
            guard let last = await collector.values.last else { return false }
            return last.contains { $0.isOwn && $0.sendState == .failed(reason: "Not delivered") }
        }
        let failed = await collector.values.last!
        XCTAssertEqual(failed.count, 1)
        XCTAssertEqual(failed.first?.sendState, .failed(reason: "Not delivered"))
        if case let .text(body, _) = failed.first?.kind {
            XCTAssertEqual(body, "hi there")
        } else {
            XCTFail("expected echo .text kind")
        }

        task.cancel()
    }

    // MARK: prompt replies must target a real journal row

    func testSendButtonResponseRejectsNonNumericPromptID() async throws {
        let store = try makeStore()
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        do {
            try await service.sendButtonResponse(selectedValues: ["Yes"], inReplyTo: "echo:abc")
            XCTFail("expected invalidPromptReference — '?? 0' used to send target_seq 0")
        } catch {
            XCTAssertEqual(error as? JournalChatError, .invalidPromptReference("echo:abc"))
        }
    }

    // MARK: echo reconciliation must not retire a failed echo

    func testReconcileSkipsFailedEchoOnDuplicateBody() async throws {
        // Two echoes with identical text: the first failed to send, the
        // second was delivered. The delivered copy's journal row must
        // retire the *pending* echo, leaving the failed one visible.
        let overlay = JournalTimelineService.OverlayState(staleness: 30)
        await overlay.addEcho(localID: "failed-one", body: "dup")
        await overlay.markEchoFailed(localID: "failed-one")
        await overlay.addEcho(localID: "delivered-one", body: "dup")

        let ownEvent = JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "user:dan", type: "text",
            payloadData: Data(#"{"body":"dup"}"#.utf8))
        await overlay.reconcile(with: [ownEvent], ownSender: "user:dan")

        let echoes = await overlay.echoes
        XCTAssertEqual(echoes.map(\.localID), ["failed-one"],
                       "the delivered echo retires; the failed one stays visible")
        XCTAssertTrue(echoes.first?.failed ?? false)
    }

    // MARK: failed echoes persist; delivered retries clear them

    func testFailedEchoSurvivesStalenessSweep() async throws {
        // A "Not delivered" row must not silently evaporate after the
        // staleness window (2026-07-13: send on a dead socket, message
        // vanished 30s later). Pending echoes still expire.
        let overlay = JournalTimelineService.OverlayState(staleness: 0.02)
        await overlay.addEcho(localID: "gone", body: "pending one")
        await overlay.addEcho(localID: "kept", body: "failed one")
        await overlay.markEchoFailed(localID: "kept")
        try await Task.sleep(for: .milliseconds(60))
        await overlay.reconcile(with: [], ownSender: "user:dan")
        let echoes = await overlay.echoes
        XCTAssertEqual(echoes.map(\.localID), ["kept"],
                       "failed echoes are exempt from staleness; pending ones expire")
    }

    func testDeliveredRetryClearsFailedEcho() async throws {
        // Only a failed copy matches the arriving own row → that row IS
        // the successful retry landing; the failure is resolved.
        let overlay = JournalTimelineService.OverlayState(staleness: 30)
        await overlay.addEcho(localID: "failed-one", body: "dup")
        await overlay.markEchoFailed(localID: "failed-one")
        let ownEvent = JournalEvent(
            seq: 1, convoID: "c1", ts: Date(), sender: "user:dan", type: "text",
            payloadData: Data(#"{"body":"dup"}"#.utf8))
        await overlay.reconcile(with: [ownEvent], ownSender: "user:dan")
        let echoes = await overlay.echoes
        XCTAssertTrue(echoes.isEmpty, "a delivered retry resolves the failed echo")
    }

    func testOldHistoryRowDoesNotClearFailedEcho() async throws {
        // reconcile re-walks the FULL event list on every emit. An old own
        // message with the same body (seen in a prior reconcile) must not
        // retire a fresh failed echo — only rows ARRIVING may (bugbot
        // "History clears failed echo").
        let overlay = JournalTimelineService.OverlayState(staleness: 30)
        let oldOwnRow = JournalEvent(
            seq: 5, convoID: "c1", ts: Date(), sender: "user:dan", type: "text",
            payloadData: Data(#"{"body":"dup"}"#.utf8))
        await overlay.reconcile(with: [oldOwnRow], ownSender: "user:dan") // row is now history
        await overlay.addEcho(localID: "fresh-fail", body: "dup")
        await overlay.markEchoFailed(localID: "fresh-fail")
        await overlay.reconcile(with: [oldOwnRow], ownSender: "user:dan") // same list re-walked
        let echoes = await overlay.echoes
        XCTAssertEqual(echoes.map(\.localID), ["fresh-fail"],
                       "an already-seen row must not resolve a newer failure")
    }

    // MARK: (g) a stalled overlay (no finalize, no further activity) self-
    // prunes via the periodic sweep instead of sitting in the snapshot
    // forever waiting for the next store/ephemeral/echo event.

    func testStalledOverlaySelfPrunesViaPeriodicSweep() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api,
                                             session: makeSession(),
                                             overlayStaleness: .milliseconds(80), sweepInterval: .milliseconds(40))
        await engine.beginSync()
        try await engine.waitUntilReady()

        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil } // initial empty snapshot

        socket.serve(#"{"kind":"ephemeral","convo_id":"c1","message_ref":"m1","replace_text":"thinking…"}"#)
        try await waitUntil { await collector.values.last?.contains { $0.id == "eph:m1" } == true }

        // No further store/ephemeral/echo activity from here on: only the
        // periodic sweep can trigger the re-emit that lets `reconcile`'s
        // staleness cutoff prune this row.
        try await waitUntil(timeout: 1) {
            guard let last = await collector.values.last else { return false }
            return !last.contains { $0.id == "eph:m1" }
        }

        task.cancel()
        await engine.endSync()
    }
}

// MARK: - Local test fakes
//
// ChatTests can't import JournalTests' fakes (separate SPM test target), so
// this mirrors the FakeWebSocketConnection / FakeConnector pair from
// MatronShared/Tests/JournalTests/FakeWebSocket.swift against the public
// `WebSocketConnection` / `WebSocketConnecting` protocols.

/// Scriptable fake socket. Push server frames with `serve(_:)`.
private final class FakeJournalSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incoming: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private(set) var sent: [String] = []

    func serve(_ text: String) {
        lock.lock()
        if let waiter = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: text)
        } else {
            incoming.append(text)
            lock.unlock()
        }
    }

    func closeFromServer() {
        lock.lock()
        closed = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume(throwing: JournalConnectionError.socketClosed) }
    }

    func sendText(_ text: String) async throws {
        lock.lock()
        defer { lock.unlock() }
        if closed { throw JournalConnectionError.socketClosed }
        sent.append(text)
    }

    func receiveText() async throws -> String {
        lock.lock()
        if !incoming.isEmpty {
            let next = incoming.removeFirst()
            lock.unlock()
            return next
        }
        if closed {
            lock.unlock()
            throw JournalConnectionError.socketClosed
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: JournalConnectionError.socketClosed)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    func ping() async throws {}
    func close() { closeFromServer() }

    /// Convenience: last sent frame decoded as a JSON object.
    var lastSentObject: [String: Any]? {
        lock.lock()
        let last = sent.last
        lock.unlock()
        guard let last else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
    }
}

/// Hands out pre-built fake connections in order.
private final class FakeJournalConnector: WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [FakeJournalSocket]

    init(_ connections: [FakeJournalSocket]) { queue = connections }

    func connect(to url: URL) async throws -> any WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        guard !queue.isEmpty else { throw JournalConnectionError.socketClosed }
        return queue.removeFirst()
    }
}

/// Records every `search.index(...)` call so `paginateBackward` tests can
/// assert on both the fed body and event id.
private actor RecordingSearchService: SearchService {
    struct Indexed { let roomID: String; let eventID: String; let sender: String; let body: String }
    private(set) var indexed: [Indexed] = []

    func index(roomID: String, eventID: String, sender: String, timestamp: Date, body: String) async throws {
        indexed.append(Indexed(roomID: roomID, eventID: eventID, sender: sender, body: body))
    }
    func remove(eventID: String) async throws {}
    func query(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func wipe() async throws {}
    func recordBackfillProgress(roomID: String, indexedCount: Int, oldestEventID: String?, complete: Bool) async throws {}
    func backfillComplete(roomID: String) async throws -> Bool { true }
    func eventCount(roomID: String) async throws -> Int { 0 }
    func contains(eventID: String) async throws -> Bool { false }
}

/// Minimal stub `URLProtocol` for `JournalAPI.messages(...)`, mirroring
/// `StubURLProtocol` in JournalTests (a separate test target, so not
/// importable here).
private final class PaginateStubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let path = request.url!.path
        let (status, body) = Self.responses[path] ?? (404, #"{"error":"not_found"}"#)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

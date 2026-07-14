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

    // MARK: sendFile / sendImage upload the bytes then send a media op

    /// Builds a service whose `api` uploads to a stubbed `POST /media`
    /// returning `mediaID`, with a live socket to capture the emitted op.
    private func makeMediaService(mediaID: String, socket: FakeJournalSocket)
        throws -> (JournalTimelineService, JournalSyncEngine) {
        let store = try makeStore()
        socket.serve(helloOK(0))
        PaginateStubURLProtocol.responses = ["/media": (200, #"{"media_id":"\#(mediaID)"}"#)]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PaginateStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://x")!, urlSession: URLSession(configuration: config))
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api, session: makeSession())
        return (service, engine)
    }

    func testSendFileUploadsMediaAndSendsFileOp() async throws {
        let socket = FakeJournalSocket()
        let (service, engine) = try makeMediaService(mediaID: "blob-9", socket: socket)
        await engine.beginSync()
        try await engine.waitUntilReady()

        try await service.sendFile(Data("hello".utf8), filename: "notes.txt", mimeType: "text/plain")

        try await waitUntil { socket.lastSentObject?["op"] as? String == "send" }
        let sent = socket.lastSentObject
        XCTAssertEqual(sent?["type"] as? String, "file")
        XCTAssertEqual(sent?["blob_ref"] as? String, "blob-9")
        XCTAssertEqual(sent?["convo_id"] as? String, "c1")
        XCTAssertNotNil(sent?["local_id"] as? String)
        let payload = sent?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["blob_ref"] as? String, "blob-9")
        XCTAssertEqual(payload?["name"] as? String, "notes.txt")
        XCTAssertEqual(payload?["content_type"] as? String, "text/plain")
        XCTAssertEqual(payload?["size"] as? Int, 5)

        await engine.endSync()
    }

    func testSendImageUploadsMediaAndSendsImageOp() async throws {
        let socket = FakeJournalSocket()
        let (service, engine) = try makeMediaService(mediaID: "blob-img", socket: socket)
        await engine.beginSync()
        try await engine.waitUntilReady()

        try await service.sendImage(Data("PNGBYTES".utf8), filename: "cat.png", mimeType: "image/png")

        try await waitUntil { socket.lastSentObject?["op"] as? String == "send" }
        let sent = socket.lastSentObject
        XCTAssertEqual(sent?["type"] as? String, "image")
        XCTAssertEqual(sent?["blob_ref"] as? String, "blob-img")
        let payload = sent?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["content_type"] as? String, "image/png")
        XCTAssertEqual(payload?["size"] as? Int, 8)

        await engine.endSync()
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

    // MARK: (h) tool_stream overlay — live command-output tiles

    /// Count of non-nil `viewing` ops the service has sent. The `items()`
    /// subscription itself sends one (baseline); every accepted resync
    /// request adds another. The teardown `viewing: null` is excluded.
    private func viewingCount(_ socket: FakeJournalSocket) -> Int {
        socket.sent.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }.filter { $0["op"] as? String == "viewing" && $0["convo_id"] is String }.count
    }

    private func toolStreamFrame(_ ref: String, _ event: String) -> String {
        #"{"kind":"ephemeral","convo_id":"c1","message_ref":"\#(ref)","tool_stream":\#(event)}"#
    }

    private func toolStreamItem(in items: [TimelineItem]?, ref: String) -> TimelineItem? {
        items?.first { $0.id == "toolstream:\(ref)" }
    }

    func testToolStreamAppendsCoalesceAndOverlapTrims() async throws {
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

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"one"}"#))
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":3,"chunk":"two"}"#))
        // Idempotent retry: bytes 3..<6 resent with 3 extra on the end.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":3,"chunk":"twoXYZ"}"#))

        try await waitUntil {
            guard case let .toolStreamLive(_, _, text, _)? =
                self.toolStreamItem(in: await collector.values.last, ref: "tu1")?.kind else { return false }
            return text == "onetwoXYZ"
        }

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamSyncReplacesContentAndSuppliesMeta() async throws {
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

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"junk"}"#))
        socket.serve(toolStreamFrame("tu1", #"{"event":"sync","meta":{"tool":"Bash","command":"make"},"offset":0,"content":"$ make\n","head_truncated":false}"#))

        try await waitUntil {
            guard case let .toolStreamLive(_, command, text, headTruncated)? =
                self.toolStreamItem(in: await collector.values.last, ref: "tu1")?.kind else { return false }
            return command == "make" && text == "$ make\n" && !headTruncated
        }

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamGapDropsChunkAndResendsViewing() async throws {
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
        try await waitUntil { self.viewingCount(socket) == 1 } // items() baseline

        // Buffer established via sync (no resync-debounce entry for tu1).
        socket.serve(toolStreamFrame("tu1", #"{"event":"sync","meta":{"tool":"Bash","command":"make"},"offset":0,"content":"ab","head_truncated":false}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") != nil }
        XCTAssertEqual(viewingCount(socket), 1)

        // Gap: end is 2, offset 999 — chunk dropped, viewing re-sent.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":999,"chunk":"lost"}"#))
        try await waitUntil { self.viewingCount(socket) == 2 }
        // A second gapped append inside the 2s debounce window adds nothing.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":999,"chunk":"lost"}"#))
        // Deterministic emit boundary: land a journal row and wait for it.
        socket.serve(journalFrame(seq: 1, payload: ["body": "marker"]))
        try await waitUntil { await collector.values.last?.contains { $0.id == "1" } == true }

        XCTAssertEqual(viewingCount(socket), 2, "debounce must swallow the second gap resync")
        guard case let .toolStreamLive(_, _, text, _)? =
            toolStreamItem(in: await collector.values.last, ref: "tu1")?.kind else {
            return XCTFail("tile missing")
        }
        XCTAssertEqual(text, "ab", "gapped chunk must be dropped, not spliced")

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamMidJoinWithoutSyncRequestsViewing() async throws {
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
        try await waitUntil { self.viewingCount(socket) == 1 }

        // No offset-0 frame ever seen: nothing to render yet, but the
        // service must ask for scrollback (a sync) by re-sending viewing.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":512,"chunk":"tail"}"#))
        try await waitUntil { self.viewingCount(socket) == 2 }
        let snapshot = await collector.values.last
        XCTAssertNil(toolStreamItem(in: snapshot, ref: "tu1"))

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamEndRemovesTile() async throws {
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

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"x"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") != nil }

        socket.serve(toolStreamFrame("tu1", #"{"event":"end","reason":"stale"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") == nil }

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamEndRetiresRefAndLateAppendIsIgnored() async throws {
        // Companion to `testDurableToolOutputRetiresTileAndLateAppendIsIgnored`:
        // an `end` frame (server idle sweep freed the buffer) must retire the
        // ref exactly like a durable row does, so a reordered/late append
        // for the same ref can't recreate a tile the server already
        // disowned (bugbot: "tool_stream end leaves ref unretired").
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

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"x"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") != nil }

        socket.serve(toolStreamFrame("tu1", #"{"event":"end","reason":"stale"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") == nil }
        let viewingsBeforeLate = viewingCount(socket)

        // Late/reordered append for the now-ended ref must not reopen the
        // tile, and must not trigger a resync viewing re-send.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":1,"chunk":"late"}"#))
        socket.serve(journalFrame(seq: 1, payload: ["body": "marker"]))
        try await waitUntil { await collector.values.last?.contains { $0.id == "1" } == true }

        let afterLate = await collector.values.last
        XCTAssertNil(toolStreamItem(in: afterLate, ref: "tu1"),
                     "late append after `end` re-opened a retired tile")
        XCTAssertEqual(viewingCount(socket), viewingsBeforeLate,
                       "retired refs must not request resyncs")

        task.cancel()
        await engine.endSync()
    }

    func testDurableToolOutputRetiresTileAndLateAppendIsIgnored() async throws {
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

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"$ make\n"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") != nil }
        let viewingsBeforeRetire = viewingCount(socket)

        // Durable completion row — the same payload shape finalize produces.
        socket.serve(journalFrame(seq: 1, type: "tool_output", payload: [
            "message_ref": "tu1", "command": "make", "exit_code": 0, "denied": false,
            "truncated": false, "snippet": "$ make", "blob_ref": "b1", "live_log": true,
        ]))
        try await waitUntil {
            guard let last = await collector.values.last else { return false }
            return last.contains { $0.id == "1" } && !last.contains { $0.id == "toolstream:tu1" }
        }

        // Late flush (protocol allows ≤200ms after the completion frame):
        // must not re-open the tile, and must not request a resync.
        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":7,"chunk":"late"}"#))
        socket.serve(journalFrame(seq: 2, payload: ["body": "marker"]))
        try await waitUntil { await collector.values.last?.contains { $0.id == "2" } == true }

        let afterLate = await collector.values.last
        XCTAssertNil(toolStreamItem(in: afterLate, ref: "tu1"),
                     "late append re-opened a retired tile")
        XCTAssertEqual(viewingCount(socket), viewingsBeforeRetire,
                       "retired refs must not request resyncs")

        task.cancel()
        await engine.endSync()
    }

    func testToolStreamSurvivesTextStalenessSweepButNotToolStaleness() async throws {
        let store = try makeStore()
        let socket = FakeJournalSocket()
        socket.serve(helloOK(0))
        let api = JournalAPI(serverURL: URL(string: "https://x")!)
        let engine = makeEngine(store: store, connector: FakeJournalConnector([socket]), api: api)
        let service = JournalTimelineService(convoID: "c1", store: store, engine: engine, api: api,
                                             session: makeSession(),
                                             overlayStaleness: .milliseconds(80),
                                             sweepInterval: .milliseconds(40),
                                             toolStreamStaleness: .milliseconds(400))
        await engine.beginSync()
        try await engine.waitUntilReady()
        let (collector, task) = collectItems(service.items())
        try await waitUntil { await collector.values.last != nil }

        socket.serve(toolStreamFrame("tu1", #"{"event":"append","offset":0,"chunk":"quiet build"}"#))
        try await waitUntil { self.toolStreamItem(in: await collector.values.last, ref: "tu1") != nil }

        // Past the text-overlay staleness (80ms) with several sweeps ticked:
        // a quiet-but-running command's tile must survive.
        try await Task.sleep(for: .milliseconds(160))
        let midway = await collector.values.last
        XCTAssertNotNil(toolStreamItem(in: midway, ref: "tu1"),
                        "tool tile swept by the text staleness cutoff")

        // Past its own staleness it self-prunes via the sweep.
        try await waitUntil(timeout: 1) {
            self.toolStreamItem(in: await collector.values.last, ref: "tu1") == nil
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

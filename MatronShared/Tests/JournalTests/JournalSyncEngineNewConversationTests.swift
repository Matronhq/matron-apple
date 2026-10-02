import XCTest
import Foundation
import MatronModels
@testable import MatronJournal

/// Which live-born conversations may open themselves
/// (`NewConversation.startedHere`). Dan, 2026-10-02: agents spawn sessions
/// all day, and both apps switched to each one as it appeared. The wire does
/// not say who started a session — a spawned session is born with the same
/// bare seed title as the user's own — so the engine opens only what this
/// device asked for: a `/start` it sent, or a `start` RPC it made (New
/// Chat). Everything else is announced with `startedHere == false`, which
/// the hosts turn into a "New" marker and nothing more.
final class JournalSyncEngineNewConversationTests: XCTestCase {
    private func helloOK(_ head: Int64) -> String {
        #"{"kind":"control","op":"hello_ok","seq":\#(head)}"#
    }

    private func statusLine(_ seq: Int64, convo: String) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"agent:a","type":"session_status","payload":{"state":"running"}}"#
    }

    /// A session's first titled `convo_meta`, as the journal fans it for a
    /// bridge's `convo_upsert`: the seed title (the workdir's name) and the
    /// box that owns it.
    private func metaLine(_ seq: Int64, convo: String, title: String = "Dev", box: Int64 = 8) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"agent:a","type":"convo_meta","payload":{"title":"\#(title)","parent_convo_id":null,"agent_device_id":\#(box),"repo":null}}"#
    }

    private func textLine(_ seq: Int64, convo: String) -> String {
        #"{"kind":"journal","seq":\#(seq),"convo_id":"\#(convo)","ts":\#(seq * 1000),"sender":"agent:a","type":"text","payload":{"body":"hello"}}"#
    }

    private func sentSendOps(_ socket: FakeWebSocketConnection) -> [[String: Any]] {
        socket.sent
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { $0["op"] as? String == "send" }
    }

    private func sentAgentRequests(_ socket: FakeWebSocketConnection) -> [[String: Any]] {
        socket.sent
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
            .filter { $0["op"] as? String == "agent_request" }
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// An engine at `.running` whose store knows one conversation, `c1`,
    /// owned by box 8, and a subscription to `newConversations()` that is
    /// already registered.
    private func runningEngine(
        startIntentWindow: Duration = .seconds(60)
    ) async throws -> (JournalSyncEngine, FakeWebSocketConnection, AsyncStream<NewConversation>.Iterator) {
        let socket = FakeWebSocketConnection()
        socket.serve(helloOK(0))
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([ConvoSummaryDTO(id: "c1", title: "[ab] Existing", sessionState: "running",
                                                     lastSeq: 0, snippet: "", createdAt: 0, agentDeviceID: 8)],
                                    headSeq: 0)
        let api = JournalAPI(serverURL: URL(string: "https://x")!) // HTTP unused: store pre-seeded
        let engine = JournalSyncEngine(api: api, store: store, connector: FakeConnector([socket]),
                                       token: "t", ownSender: "user:dan", search: nil,
                                       backoffBaseSeconds: 0.01, startIntentWindow: startIntentWindow)
        await engine.beginSync()
        try await engine.waitUntilReady()
        let iterator = engine.newConversations().makeAsyncIterator()
        // Publishing only reaches registered continuations.
        try await Task.sleep(for: .milliseconds(50))
        return (engine, socket, iterator)
    }

    /// The bug. An agent's `agent_session_start` is approved and the target
    /// bridge starts the session: session_status, then a `convo_meta` with
    /// the bare seed title. Nothing on this device asked for it, so it is
    /// announced quietly.
    func testSessionNobodyAskedForHereArrivesQuietly() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        socket.serve(statusLine(1, convo: "cSpawn"))
        socket.serve(metaLine(2, convo: "cSpawn"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false),
                       "a session this device did not ask for must not open itself")
        await engine.endSync()
    }

    /// A session whose first frame is a message (no meta yet) is no more
    /// the user's own than one that leads with its meta.
    func testMessageFirstSessionNobodyAskedForArrivesQuietly() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        socket.serve(textLine(1, convo: "cSpawn"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false))
        await engine.endSync()
    }

    /// `/start` sent from this device: the session it creates opens, and
    /// the ask is spent — the next session born on that box is somebody
    /// else's.
    func testStartSentFromHereOpensTheSessionItCreatesAndOnlyThat() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start ~/Dev/app", localID: "L1")
        socket.serve(statusLine(1, convo: "cMine"))
        socket.serve(metaLine(2, convo: "cMine"))
        socket.serve(metaLine(3, convo: "cSpawn"))
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true),
                       "the session a /start from this device created must still open")
        let spawned = await iterator.next()
        XCTAssertEqual(spawned, NewConversation(id: "cSpawn", startedHere: false),
                       "one /start opens one session")
        await engine.endSync()
    }

    /// The bridge takes `!start` too, in any case.
    func testBangStartCountsAsAStart() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "!Start --browser", localID: "L1")
        socket.serve(metaLine(1, convo: "cMine"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cMine", startedHere: true))
        await engine.endSync()
    }

    /// Any other message is not an ask, even one that mentions the command.
    func testAnOrdinaryMessageIsNotAStart() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "run /start for me", localID: "L1")
        socket.serve(metaLine(1, convo: "cSpawn"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false))
        await engine.endSync()
    }

    /// A `/start` asks the box that owns the conversation it was sent in.
    /// A session born on another box while that ask is open is not its
    /// answer; the one born on the asked box still is.
    func testStartIsAnsweredOnlyByTheBoxItWasSentTo() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1") // c1 lives on box 8
        socket.serve(metaLine(1, convo: "cElsewhere", box: 9))
        socket.serve(metaLine(2, convo: "cMine", box: 8))
        let elsewhere = await iterator.next()
        XCTAssertEqual(elsewhere, NewConversation(id: "cElsewhere", startedHere: false),
                       "a session born on a box that was not asked must not open")
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true))
        await engine.endSync()
    }

    /// A session whose first frame is a message has not said which box it
    /// is on. While a start is waiting for a session on a particular box,
    /// it must not take that ask on a guess (Bugbot, PR 300): its verdict
    /// waits for the title, and the user's own session still opens.
    func testMessageFirstSessionDoesNotTakeAnAskMeantForAnotherBox() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1") // asks box 8
        socket.serve(textLine(1, convo: "cSpawn"))
        socket.serve(metaLine(2, convo: "cSpawn", box: 9))
        socket.serve(metaLine(3, convo: "cMine", box: 8))
        let spawned = await iterator.next()
        XCTAssertEqual(spawned, NewConversation(id: "cSpawn", startedHere: false),
                       "a session that had not named its box must not take the ask")
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true),
                       "the ask is still there for the session it was meant for")
        await engine.endSync()
    }

    /// The same wait, resolved the other way: the title puts the
    /// message-first session on the asked box, so it is the answer.
    func testMessageFirstSessionOnTheAskedBoxOpensOnceItsTitleSaysSo() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1") // asks box 8
        socket.serve(textLine(1, convo: "cMine"))
        socket.serve(metaLine(2, convo: "cMine", box: 8))
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true))
        await engine.endSync()
    }

    /// A `/start` the user discarded from the outbox never reaches the
    /// box, so the next session born there is not its answer (Bugbot,
    /// PR 300).
    func testDiscardedStartIsNoLongerAnAsk() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1")
        await engine.discardOutboxItem(localID: "L1")
        socket.serve(metaLine(1, convo: "cSpawn"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false))
        await engine.endSync()
    }

    /// A `/start` the server rejected never reaches the box either. A
    /// tap-to-retry asks again.
    func testRejectedStartIsNoLongerAnAsk_untilItIsRetried() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1")
        await waitUntil(!self.sentSendOps(socket).isEmpty)
        socket.serve(#"{"kind":"control","op":"error","code":"bad_request","ref":"send","detail":"nope"}"#)
        socket.serve(metaLine(1, convo: "cSpawn"))
        let spawned = await iterator.next()
        XCTAssertEqual(spawned, NewConversation(id: "cSpawn", startedHere: false),
                       "a rejected /start leaves no ask behind")

        await engine.retryOutboxItem(localID: "L1")
        socket.serve(metaLine(2, convo: "cMine"))
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true), "a retry asks again")
        await engine.endSync()
    }

    /// An ask does not stay open for ever: a session that turns up after
    /// the window (a box that had to be woken, say) lands in the list
    /// rather than interrupting whatever the user has moved on to.
    func testAStartAskExpires() async throws {
        var (engine, socket, iterator) = try await runningEngine(startIntentWindow: .milliseconds(40))
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1")
        try await Task.sleep(for: .milliseconds(200))
        socket.serve(metaLine(1, convo: "cLate"))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cLate", startedHere: false))
        await engine.endSync()
    }

    /// A title already wearing the spawned-session marker is another
    /// agent's session whatever this device asked for, and leaves the ask
    /// for the session that does answer it.
    func testSpawnMarkedTitleNeverAnswersAStart() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        try await engine.sendMessage(convoID: "c1", body: "/start", localID: "L1")
        socket.serve(metaLine(1, convo: "cSpawn", title: "🐣 [ab] Fix the login page"))
        socket.serve(metaLine(2, convo: "cMine"))
        let spawned = await iterator.next()
        XCTAssertEqual(spawned, NewConversation(id: "cSpawn", startedHere: false))
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true))
        await engine.endSync()
    }

    /// New Chat: the session can be born before its `start` RPC is
    /// answered. The request in flight is the ask.
    func testStartRPCInFlightOpensTheSessionBornOnThatBox() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        let reply = Task {
            try await engine.agentRequest(agentDeviceID: 9, method: "start", paramsData: Data("{}".utf8))
        }
        await waitUntil(!self.sentAgentRequests(socket).isEmpty)
        socket.serve(metaLine(1, convo: "cMine", box: 9))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cMine", startedHere: true))
        let rid = try XCTUnwrap(sentAgentRequests(socket).first?["request_id"] as? String)
        socket.serve(#"{"kind":"rpc","response":{"request_id":"\#(rid)","agent_device_id":9,"ok":true,"result":{"convo_id":"cMine"}}}"#)
        _ = try await reply.value
        await engine.endSync()
    }

    /// New Chat, the other order: the RPC answers first and names the
    /// conversation. From then on only that conversation is the answer — a
    /// spawn born on the same box in between does not open, and the named
    /// one does when its frames arrive.
    func testStartRPCAnswerNamesTheOnlySessionThatOpens() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        let reply = Task {
            try await engine.agentRequest(agentDeviceID: 9, method: "start", paramsData: Data("{}".utf8))
        }
        await waitUntil(!self.sentAgentRequests(socket).isEmpty)
        let rid = try XCTUnwrap(sentAgentRequests(socket).first?["request_id"] as? String)
        socket.serve(#"{"kind":"rpc","response":{"request_id":"\#(rid)","agent_device_id":9,"ok":true,"result":{"convo_id":"cMine"}}}"#)
        _ = try await reply.value

        socket.serve(metaLine(1, convo: "cSpawn", box: 9))
        socket.serve(statusLine(2, convo: "cMine"))
        socket.serve(metaLine(3, convo: "cMine", box: 9))
        let spawned = await iterator.next()
        XCTAssertEqual(spawned, NewConversation(id: "cSpawn", startedHere: false),
                       "an answered start is settled; another session on the box is not its answer")
        let mine = await iterator.next()
        XCTAssertEqual(mine, NewConversation(id: "cMine", startedHere: true))
        await engine.endSync()
    }

    /// A refused `start` creates nothing, so it leaves nothing to claim.
    func testRefusedStartRPCLeavesNoAskBehind() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        let reply = Task {
            try await engine.agentRequest(agentDeviceID: 9, method: "start", paramsData: Data("{}".utf8))
        }
        await waitUntil(!self.sentAgentRequests(socket).isEmpty)
        let rid = try XCTUnwrap(sentAgentRequests(socket).first?["request_id"] as? String)
        socket.serve(#"{"kind":"rpc","response":{"request_id":"\#(rid)","agent_device_id":9,"ok":false,"error":{"code":"bad_workdir"}}}"#)
        guard case .failure = try await reply.value else { return XCTFail("expected a refusal") }

        socket.serve(metaLine(1, convo: "cSpawn", box: 9))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false))
        await engine.endSync()
    }

    /// Other RPCs (the New Chat sheet asks for recent folders before it
    /// ever starts anything) are not asks for a session.
    func testOtherRPCsAreNotStarts() async throws {
        var (engine, socket, iterator) = try await runningEngine()
        let reply = Task {
            try await engine.agentRequest(agentDeviceID: 9, method: "recent_folders", paramsData: Data("{}".utf8))
        }
        await waitUntil(!self.sentAgentRequests(socket).isEmpty)
        socket.serve(metaLine(1, convo: "cSpawn", box: 9))
        let born = await iterator.next()
        XCTAssertEqual(born, NewConversation(id: "cSpawn", startedHere: false))
        let rid = try XCTUnwrap(sentAgentRequests(socket).first?["request_id"] as? String)
        socket.serve(#"{"kind":"rpc","response":{"request_id":"\#(rid)","agent_device_id":9,"ok":true,"result":{"folders":[]}}}"#)
        _ = try await reply.value
        await engine.endSync()
    }

    // MARK: LocalStartIntents

    func testStartCommandGrammar() {
        for line in ["/start", "!start", "/start ~/Dev/app", "  /START --browser ~/x", "!Start\n"] {
            XCTAssertTrue(LocalStartIntents.isStartCommand(line), "a start: \(line)")
        }
        for line in ["", "start", "/starter", "/workdir ~/x", "please /start", "/ start", "//start"] {
            XCTAssertFalse(LocalStartIntents.isStartCommand(line), "not a start: \(line)")
        }
    }

    /// A wake-and-retry New Chat asks one box several times for one
    /// session. The copies must not outlive the session they were for.
    func testRepeatedAsksOfOneBoxAreOneAsk() {
        var intents = LocalStartIntents()
        let now = ContinuousClock.now
        intents.note(agentDeviceID: 9, now: now)
        intents.note(agentDeviceID: 9, now: now + .seconds(5))
        XCTAssertTrue(intents.claim(agentDeviceID: 9, now: now + .seconds(6)))
        XCTAssertFalse(intents.claim(agentDeviceID: 9, now: now + .seconds(7)),
                       "retries of one start are one ask, not several")
    }

    func testAnAskWithNoKnownBoxIsAnsweredByAnyBox() {
        var intents = LocalStartIntents()
        intents.note(agentDeviceID: nil)
        XCTAssertTrue(intents.claim(agentDeviceID: 9))
        XCTAssertFalse(intents.claim(agentDeviceID: 9))
    }

    /// A conversation that has not named its box (nil) cannot be judged
    /// against an ask for a particular one, and must not spend it.
    func testAConversationWithNoKnownBoxCannotTakeAnAskForAKnownBox() {
        var intents = LocalStartIntents()
        XCTAssertFalse(intents.awaitsKnownBox())
        intents.note(agentDeviceID: 8)
        XCTAssertTrue(intents.awaitsKnownBox())
        XCTAssertFalse(intents.claim(agentDeviceID: nil))
        XCTAssertTrue(intents.claim(agentDeviceID: 8), "the ask survived the unknown-box conversation")
        XCTAssertFalse(intents.awaitsKnownBox())
    }

    func testAnExpiredAskAwaitsNothing() {
        var intents = LocalStartIntents(window: .seconds(60))
        let now = ContinuousClock.now
        intents.note(agentDeviceID: 8, now: now)
        XCTAssertTrue(intents.awaitsKnownBox(now: now + .seconds(59)))
        XCTAssertFalse(intents.awaitsKnownBox(now: now + .seconds(61)))
        XCTAssertFalse(intents.claim(agentDeviceID: 8, now: now + .seconds(61)))
    }

    func testAnAskIsKeptForItsOwnBoxWhenAnotherBoxIsBorn() {
        var intents = LocalStartIntents()
        intents.note(agentDeviceID: 8)
        XCTAssertFalse(intents.claim(agentDeviceID: 9))
        XCTAssertTrue(intents.claim(agentDeviceID: 8))
    }
}

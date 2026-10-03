import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

@MainActor
final class JournalVoiceFeedTests: XCTestCase {
    static let text = VoiceTextMaker(
        short: { String($0.prefix(while: { $0 != "." })) + ($0.isEmpty ? "" : ".") },
        sections: { $0.isEmpty ? [] : [$0] },
        plain: { $0.replacingOccurrences(of: "**", with: "") })

    var store: JournalStore!
    var nextSeq: Int64 = 1
    var collected: [VoiceModeEngine.Event] = []
    var collector: Task<Void, Never>?

    override func setUp() async throws {
        store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        nextSeq = 1
        collected = []
    }

    override func tearDown() async throws {
        collector?.cancel()
    }

    @discardableResult
    func apply(_ type: String, convo: String = "c1", sender: String = "agent:bev", _ payload: [String: Any]) throws -> Int64 {
        let seq = nextSeq
        nextSeq += 1
        _ = try store.applyJournal(JournalEvent(seq: seq, convoID: convo, ts: Date(), sender: sender, type: type,
                                                payloadData: try JSONSerialization.data(withJSONObject: payload)))
        return seq
    }

    func makeFeed(_ scope: JournalVoiceFeed.Scope = .conversation("c1"), summaryWait: TimeInterval = 0.2) -> JournalVoiceFeed {
        let feed = JournalVoiceFeed(store: store, text: Self.text, scope: scope, summaryWait: summaryWait, poll: 0.02, needsPoll: 0.05)
        let events = feed.events
        collector = Task { [weak self] in
            for await event in events { self?.collected.append(event) }
        }
        return feed
    }

    /// For "nothing more happens": long enough for a delivery to land.
    func settle(_ seconds: TimeInterval = 0.4) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// For "this happens": returns as soon as it has. Sleeps under a test
    /// host are coarse (20 ms can take 150), so nothing here asserts on a
    /// fixed delay.
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    var arrivedIDs: [String] {
        collected.compactMap { event -> String? in
            if case .arrived(let entry) = event { return entry.id } else { return nil }
        }
    }

    var arrivedReplies: [SpokenReply] {
        collected.compactMap { event -> SpokenReply? in
            if case .arrived(let entry) = event, case .reply(let reply) = entry.subject { return reply }
            return nil
        }
    }

    func testATurnEndingWithASummarySpeaksTheBridgesLines() async throws {
        try apply("convo_meta", ["title": "[ab] Auth refactor"])
        try apply("session_status", ["state": "waiting"])
        let feed = makeFeed()
        feed.watch(convoID: "c1")
        await settle()
        try apply("session_status", ["state": "running"])
        await settle()
        let seq = try apply("text", ["body": "The deploy finished. All green.", "message_ref": "m1"])
        try apply("summary", ["toc": "Deploy", "spoken": "The deploy is done.", "spoken_more": "Every test passed.", "spoken_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies, [SpokenReply(convoID: "c1", seq: seq, short: "The deploy is done.",
                                                    more: "Every test passed.", sections: ["The deploy finished. All green."])])
        XCTAssertTrue(collected.contains(.turnStarted(convoID: "c1")))
        XCTAssertTrue(collected.contains(.turnEnded(convoID: "c1")))
        if case .arrived(let entry)? = collected.last {
            XCTAssertEqual(entry.convoTitle, "Auth refactor")
        } else {
            XCTFail("the reply arrives last")
        }
        feed.stop()
    }

    func testNoSummaryFallsBackToTheCleanerAfterTheWait() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 0.1)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "The deploy finished. All green.", "message_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        XCTAssertEqual(arrivedReplies, [], "it waits for the summary first")
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["The deploy finished."])
        XCTAssertNil(arrivedReplies.first?.more)
        XCTAssertEqual(arrivedReplies.first?.sections, ["The deploy finished. All green."])
        feed.stop()
    }

    func testASummaryThatLandsDuringTheWaitIsUsed() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 30)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "Long answer. With detail.", "message_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await settle()
        XCTAssertEqual(arrivedReplies, [])
        try apply("summary", ["toc": "T", "spoken": "Short answer.", "spoken_ref": "m1"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["Short answer."])
        feed.stop()
    }

    /// A summary for an older reply must not be said for the newest one.
    func testALateSummaryForAnOlderReplyIsIgnored() async throws {
        try apply("session_status", ["state": "running"])
        let feed = makeFeed(summaryWait: 0.1)
        feed.watch(convoID: "c1")
        await settle()
        try apply("text", ["body": "Old reply. Detail.", "message_ref": "m1"])
        try apply("text", ["body": "New reply. Detail.", "message_ref": "m2"])
        try apply("summary", ["toc": "T", "spoken": "About the old one.", "spoken_ref": "m1"])
        try apply("session_status", ["state": "waiting"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["New reply."])
        feed.stop()
    }

    func testWhatWasAlreadyThereIsNotSpoken() async throws {
        try apply("text", ["body": "Yesterday's reply.", "message_ref": "m0"])
        try apply("session_status", ["state": "waiting"])
        let feed = makeFeed(summaryWait: 0.05)
        feed.watch(convoID: "c1")
        await settle()
        XCTAssertEqual(arrivedReplies, [])
        // A message that is its own summary has nothing more to read.
        try apply("text", ["body": "Done.", "message_ref": "m1"])
        await waitUntil { !self.arrivedReplies.isEmpty }
        XCTAssertEqual(arrivedReplies.map(\.short), ["Done."])
        XCTAssertEqual(arrivedReplies.first?.sections, [])
        feed.stop()
    }

    func testAPromptArrivesAndIsResolvedWhenAnswered() async throws {
        try apply("convo_meta", ["title": "[ab] Schema"])
        let feed = makeFeed(.everything)
        feed.startWatchingNeeds()
        await settle()
        let seq = try apply("prompt", ["question": "Which **database**?", "options": ["Postgres", "SQLite"]])
        await waitUntil { !self.arrivedIDs.isEmpty }
        guard case .arrived(let entry)? = collected.last, case .prompt(let prompt) = entry.subject else {
            return XCTFail("the prompt arrives: \(collected)")
        }
        XCTAssertEqual(prompt.question, "Which database?", "through the cleaner")
        XCTAssertEqual(entry.id, "prompt:\(seq)")
        try apply("prompt_reply", sender: "user:dan", ["target_seq": seq, "choice": "Postgres"])
        await waitUntil { self.collected.last == .resolved(id: "prompt:\(seq)", expired: false) }
        XCTAssertEqual(collected.last, .resolved(id: "prompt:\(seq)", expired: false))
        feed.stop()
    }

    func testInAConversationOnlyItsOwnPromptsArriveAndWaitingItemsAreNotReadOut() async throws {
        try store.upsertItems([TrackerItem(id: "it_old", num: 1, kind: .question, awaiting: .user, title: "Old", originConvoID: "c1")])
        try apply("prompt", convo: "c1", ["question": "Here?", "options": ["Yes", "No"]])
        try apply("prompt", convo: "c2", ["question": "Elsewhere?", "options": ["Yes", "No"]])
        let feed = makeFeed(.conversation("c1"))
        feed.startWatchingNeeds()
        await waitUntil { !self.arrivedIDs.isEmpty }
        await settle()
        XCTAssertEqual(arrivedIDs, ["prompt:1"])
        try store.upsertItems([TrackerItem(id: "it_new", num: 2, kind: .decision, awaiting: .user, title: "New",
                                           originConvoID: "c1", actions: ["Go"])])
        await waitUntil { self.arrivedIDs.count == 2 }
        XCTAssertEqual(collected.last, .arrived(.item(VoiceItem(id: "it_new", kind: .decision, convoID: "c1", title: "New",
                                                                labels: ["Go"]), convoTitle: "")))
        feed.stop()
    }

    func testTheInitialQueueIsReadableAndNotAnnouncedAgain() async throws {
        try apply("convo_meta", convo: "c1", ["title": "[ab] Auth refactor"])
        try apply("text", convo: "c1", ["body": "All merged. Nothing left.", "message_ref": "m1"])
        try apply("summary", convo: "c1", ["toc": "T", "spoken": "It is merged.", "spoken_ref": "m1"])
        try apply("session_status", convo: "c1", ["state": "waiting"])
        try apply("prompt", convo: "c2", ["question": "Ship it?", "options": ["Yes", "No"]])
        try store.upsertItems([TrackerItem(id: "it_a", num: 7, kind: .question, awaiting: .user, title: "Pick a colour",
                                           body: "Red or blue.", originConvoID: "c1", actions: ["Red", "Blue"])])
        let feed = makeFeed(.everything)
        let queue = feed.initialQueue()
        XCTAssertEqual(queue.map(\.id), ["prompt:5", "item:it_a", "reply:c1:2"])
        if case .reply(let reply) = queue[2].subject {
            XCTAssertEqual(reply.short, "It is merged.")
        } else {
            XCTFail("the unseen reply is last")
        }
        if case .item(let item) = queue[1].subject {
            XCTAssertEqual(item.sections, ["Red or blue."])
            XCTAssertEqual(item.labels, ["Red", "Blue"])
        } else {
            XCTFail("the item is second")
        }
        feed.startWatchingNeeds()
        feed.watch(convoID: "c1")
        await settle()
        XCTAssertFalse(collected.contains { if case .arrived = $0 { return true } else { return false } },
                       "nothing in the queue arrives a second time")
        XCTAssertEqual(feed.lastConversation()?.id, "c2")
        XCTAssertEqual(feed.lastConversation(excluding: "c2")?.title, "Auth refactor")
        feed.stop()
    }
}

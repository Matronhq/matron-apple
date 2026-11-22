import GRDB
import XCTest
import MatronEvents
import MatronModels
@testable import MatronJournal

/// Multi-select answers: `multi_select` and `chosen_actions` on items and
/// comments, `selected` on an answer, and the `{selected, reply_to?}`
/// reply. A journal that predates them sends none of the keys, so each
/// defaults rather than failing the decode.
final class MultiSelectAnswersTests: XCTestCase {
    private static let commentJSON: [String: Any] = [
        "id": "ic_1", "item_id": "it_1", "user_id": 1, "author": "agent", "device_id": 9, "kind": "comment",
        "body": "Which missions should close?", "attachments": [], "meta": NSNull(), "idem_key": NSNull(),
        "created_at": 1_700_000_002_000,
    ]

    // MARK: Decoding

    func testItemDecodesMultiSelectAndEveryChosenLabel() throws {
        var json = ItemsAPITests.itemJSON
        json["actions"] = ["Close the Docs mission", "Close the Billing mission", "Close the Search mission"]
        json["multi_select"] = true
        json["chosen_action"] = "Close the Docs mission"
        json["chosen_actions"] = ["Close the Docs mission", "Close the Search mission"]
        let item = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertTrue(item.multiSelect)
        XCTAssertEqual(item.chosenActions, ["Close the Docs mission", "Close the Search mission"])
        XCTAssertEqual(item.chosenAction, "Close the Docs mission")
    }

    func testItemWithoutTheNewKeysIsOneTapAndReadsItsAnswerFromChosenAction() throws {
        let plain = try XCTUnwrap(TrackerItem(json: ItemsAPITests.itemJSON))
        XCTAssertFalse(plain.multiSelect)
        XCTAssertEqual(plain.chosenActions, [])

        var json = ItemsAPITests.itemJSON
        json["actions"] = ["Go", "Wait"]
        json["chosen_action"] = "Go"
        let tapped = try XCTUnwrap(TrackerItem(json: json))
        XCTAssertFalse(tapped.multiSelect)
        XCTAssertEqual(tapped.chosenActions, ["Go"], "an older journal's one-tap answer reads as one label")
    }

    func testCommentDecodesItsQuestionAndAnAnswersSelection() throws {
        var asking = Self.commentJSON
        asking["actions"] = ["Docs", "Billing"]
        asking["multi_select"] = true
        asking["chosen_actions"] = ["Docs", "Billing"]
        asking["chosen_action"] = "Docs"
        let question = try XCTUnwrap(TrackerComment(json: asking))
        XCTAssertTrue(question.multiSelect)
        XCTAssertEqual(question.chosenActions, ["Docs", "Billing"])

        var answer = Self.commentJSON
        answer["author"] = "user"; answer["body"] = "Docs, Billing"; answer["action"] = "Docs"
        answer["selected"] = ["Docs", "Billing"]; answer["reply_to"] = "ic_ask"
        let reply = try XCTUnwrap(TrackerComment(json: answer))
        XCTAssertEqual(reply.selected, ["Docs", "Billing"])
        XCTAssertEqual(reply.action, "Docs")
        XCTAssertEqual(reply.replyTo, "ic_ask")
    }

    func testCommentWithoutTheNewKeysHasNoSelection() throws {
        let c = try XCTUnwrap(TrackerComment(json: Self.commentJSON))
        XCTAssertFalse(c.multiSelect)
        XCTAssertEqual(c.chosenActions, [])
        XCTAssertEqual(c.selected, [])
    }

    func testThreadBodyListsEveryTickedLabel() {
        func answer(_ body: String, _ selected: [String]) -> TrackerComment {
            TrackerComment(id: "ic_2", itemID: "it_1", author: .user, body: body, action: selected.first, selected: selected)
        }
        XCTAssertEqual(answer("Docs, Billing", ["Docs", "Billing"]).threadBody, "Docs, Billing")
        XCTAssertEqual(answer("", ["Docs", "Billing"]).threadBody, "Docs, Billing")
        XCTAssertEqual(answer("Both, please", ["Docs", "Billing"]).threadBody, "Docs, Billing\n\nBoth, please")
        XCTAssertEqual(TrackerComment(id: "ic_3", itemID: "it_1", author: .user, body: "Go", action: "Go").threadBody, "Go",
                       "a one-tap answer reads as before")
    }

    func testAMultiSelectConsentQuestionIsNotAnsweredFromItsRow() {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "Q", labels: ["consent"],
                               originConvoID: "c1", actions: ["Approve", "Decline"], multiSelect: true)
        XCTAssertEqual(item.rowConsentAnswers, [])
    }

    func testMarkerCarriesAnAnswersSelection() throws {
        let marker = try XCTUnwrap(ItemMarkerEvent.parse(payload: [
            "item_id": "it_1", "num": 1, "kind": "question", "title": "Q", "action": "commented", "by": "user",
            "comment": ["id": "ic_2", "body": "Docs, Billing", "action": "Docs", "reply_to": "ic_ask",
                        "selected": ["Docs", "Billing"]],
        ]))
        XCTAssertEqual(marker.comment?.selected, ["Docs", "Billing"])
        let tap = try XCTUnwrap(ItemMarkerEvent.parse(payload: [
            "item_id": "it_1", "num": 1, "kind": "question", "title": "Q", "action": "commented", "by": "user",
            "comment": ["id": "ic_2", "body": "Go", "action": "Go"],
        ]))
        XCTAssertEqual(tap.comment?.selected, [])
    }

    // MARK: Local store

    func testStoreRoundTripsTheItemsAndCommentsFields() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "Q", originConvoID: "c1",
                               actions: ["Docs", "Billing", "Search"], chosenAction: "Docs",
                               multiSelect: true, chosenActions: ["Docs", "Search"])
        try store.upsertItems([item])
        let read = try XCTUnwrap(try store.item(id: "it_1"))
        XCTAssertTrue(read.multiSelect)
        XCTAssertEqual(read.chosenActions, ["Docs", "Search"])

        let oneTap = TrackerItem(id: "it_2", num: 2, kind: .question, title: "Q", originConvoID: "c1",
                                 actions: ["Go"], chosenAction: "Go")
        try store.upsertItems([oneTap])
        XCTAssertEqual(try store.item(id: "it_2")?.chosenActions, ["Go"])
        XCTAssertEqual(try store.item(id: "it_2")?.multiSelect, false)

        let asking = TrackerComment(id: "ic_ask", itemID: "it_1", author: .agent, body: "Which?", createdAt: Date(timeIntervalSince1970: 1),
                                    actions: ["Docs", "Billing"], chosenAction: "Docs", multiSelect: true,
                                    chosenActions: ["Docs", "Billing"])
        let answer = TrackerComment(id: "ic_ans", itemID: "it_1", author: .user, body: "Docs, Billing", createdAt: Date(timeIntervalSince1970: 2),
                                    action: "Docs", replyTo: "ic_ask", selected: ["Docs", "Billing"])
        try store.replaceComments(itemID: "it_1", [asking, answer])
        XCTAssertEqual(try store.comments(itemID: "it_1"), [asking, answer])
    }

    func testTheMigrationAddsTheColumnsAndForcesAFullRefetch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.sqlite")
        do {
            let dbQueue = try DatabaseQueue(path: url.path)
            try JournalStore.migrator().migrate(dbQueue, upTo: "item_step_up")
            try dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO item(id, num, kind, state, rank, title, body, labels_json, links_json, attachments_json,
                                     origin_convo_id, created_by, created_at, updated_at, comment_count, has_image,
                                     actions_json, chosen_action)
                    VALUES('it_1', 1, 'question', 'open', 1024, 'Q', '', '[]', '[]', '[]', 'c1', 'agent', 0, 0, 0, 0,
                           '["Go"]', 'Go')
                    """)
                try db.execute(sql: "INSERT INTO meta(key, value) VALUES('items_watermark_all', 5)")
            }
        }
        let store = try JournalStore(databaseURL: url, ownSender: "user:alice")
        let item = try XCTUnwrap(try store.item(id: "it_1"))
        XCTAssertFalse(item.multiSelect)
        XCTAssertEqual(item.chosenActions, ["Go"])
        XCTAssertNil(try store.itemsWatermark(scope: .all))
    }

    func testMarkingASelectionTouchesOnlyACommentOfferingEveryLabel() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let asking = TrackerComment(id: "ic_ask", itemID: "it_1", author: .agent, body: "Which?",
                                    actions: ["Docs", "Billing"], multiSelect: true)
        try store.replaceComments(itemID: "it_1", [asking])
        try store.markCommentSelectionChosen(itemID: "it_1", commentID: "ic_ask", labels: ["Docs", "Search"])
        XCTAssertEqual(try store.comments(itemID: "it_1").first?.chosenActions, [], "Search is not offered")
        try store.markCommentSelectionChosen(itemID: "it_other", commentID: "ic_ask", labels: ["Docs"])
        XCTAssertEqual(try store.comments(itemID: "it_1").first?.chosenActions, [])
        try store.markCommentSelectionChosen(itemID: "it_1", commentID: "ic_ask", labels: ["Docs", "Billing"])
        let marked = try XCTUnwrap(try store.comments(itemID: "it_1").first)
        XCTAssertEqual(marked.chosenActions, ["Docs", "Billing"])
        XCTAssertEqual(marked.chosenAction, "Docs")
        XCTAssertTrue(marked.multiSelect)
    }

    func testOutboxRowReportsTheLabelsItTicks() {
        func row(_ payload: String, op: String = "comment") -> ItemOutboxRecord {
            ItemOutboxRecord(localID: "L1", itemID: "it_1", op: op, payloadJSON: payload, createdAt: 1, attempts: 0, lastError: nil)
        }
        let answer = row(#"{"body":"Docs, Billing","attachments":[],"selected":["Docs","Billing"],"replyTo":"ic_ask"}"#)
        XCTAssertEqual(answer.commentSelected, ["Docs", "Billing"])
        XCTAssertEqual(answer.commentReplyTo, "ic_ask")
        XCTAssertNil(answer.commentAction, "an answer is never a tap")
        XCTAssertNil(row(#"{"body":"Go","attachments":[],"action":"Go"}"#).commentSelected)
        XCTAssertNil(row(#"{"selected":["Docs"]}"#, op: "create").commentSelected)
    }

    // MARK: API

    func testTheRequestCarriesSelectedAndReplyToButNeverAnAction() {
        let item = JournalAPI.commentRequestJSON(body: "Docs, Billing", action: nil, selected: ["Docs", "Billing"], replyTo: nil)
        XCTAssertEqual(item["selected"] as? [String], ["Docs", "Billing"])
        XCTAssertEqual(item["body"] as? String, "Docs, Billing")
        XCTAssertNil(item["action"])
        XCTAssertNil(item["reply_to"])

        let followUp = JournalAPI.commentRequestJSON(body: "", action: "Docs", selected: ["Docs"], replyTo: "ic_ask")
        XCTAssertEqual(followUp["selected"] as? [String], ["Docs"])
        XCTAssertEqual(followUp["reply_to"] as? String, "ic_ask")
        XCTAssertNil(followUp["action"], "action and selected are never sent together")

        let tap = JournalAPI.commentRequestJSON(body: "Go", action: "Go", replyTo: "ic_ask")
        XCTAssertEqual(tap["action"] as? String, "Go")
        XCTAssertNil(tap["selected"], "a one-tap answer is sent exactly as before")
    }

    func testAnswerItemPostsTheSelectionAndDecodesTheAnswer() async throws {
        ItemsStubURLProtocol.status = 201
        var answer = Self.commentJSON
        answer["author"] = "user"; answer["body"] = "Docs, Billing"; answer["action"] = "Docs"
        answer["selected"] = ["Docs", "Billing"]; answer["reply_to"] = "ic_ask"
        ItemsStubURLProtocol.body = try JSONSerialization.data(withJSONObject: ["item": ItemsAPITests.itemJSON, "comment": answer])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        let api = JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                             urlSession: URLSession(configuration: config), token: "t")

        let r = try await api.answerItem(id: "it_1", selected: ["Docs", "Billing"], body: "Docs, Billing", replyTo: "ic_ask",
                                         idempotencyKey: "k")
        XCTAssertEqual(r.comment?.selected, ["Docs", "Billing"])
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key"), "k")
        let sent = try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as! [String: Any]
        XCTAssertEqual(sent["selected"] as? [String], ["Docs", "Billing"])
        XCTAssertEqual(sent["reply_to"] as? String, "ic_ask")
        XCTAssertNil(sent["action"])
    }

    // MARK: Outbox

    private final class AnsweringAPI: ItemsProviding, @unchecked Sendable {
        let lock = NSLock()
        private var _answers: [(selected: [String], replyTo: String?, key: String?)] = []
        private var _typed: [String] = []
        var refuseLabels = false
        var answers: [(selected: [String], replyTo: String?, key: String?)] { lock.withLock { _answers } }
        var typed: [String] { lock.withLock { _typed } }

        func answerItem(id: String, selected: [String], body: String, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) {
            lock.withLock { _answers.append((selected, replyTo, idempotencyKey)) }
            if refuseLabels { throw JournalAPIError.http(status: 400, message: "unknown_action") }
            let item = TrackerItem(id: id, num: 1, kind: .question, awaiting: .agent, title: "Q", originConvoID: "c1",
                                   actions: ["Docs", "Billing"], multiSelect: true,
                                   chosenActions: replyTo == nil ? selected : [])
            return (item, TrackerComment(id: "ic_srv", itemID: id, author: .user, body: body, action: selected.first,
                                         replyTo: replyTo, selected: selected))
        }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment?) {
            lock.withLock { _typed.append(body) }
            return (TrackerItem(id: id, num: 1, kind: .question, title: "Q", originConvoID: "c1"),
                    TrackerComment(id: "ic_typed", itemID: id, author: .user, body: body))
        }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { ItemsPage(items: [], nextCursor: nil) }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { throw JournalAPIError.transport("offline") }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { "blob" }
    }

    private func makeSync(_ api: AnsweringAPI) async throws -> (ItemsSync, JournalStore) {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let (markers, _) = AsyncStream<(convoID: String, marker: ItemMarkerEvent)>.makeStream()
        let (states, _) = AsyncStream<SyncConnectionState>.makeStream()
        let sync = ItemsSync(api: api, store: store, markers: { markers }, connectionStates: { states }, reconcileInterval: nil)
        await sync.start()
        return (sync, store)
    }

    func testAQueuedAnswerPostsTheSelectionAndMarksTheAskingComment() async throws {
        let api = AnsweringAPI()
        let (sync, store) = try await makeSync(api)
        try store.replaceComments(itemID: "it_1", [
            TrackerComment(id: "ic_ask", itemID: "it_1", author: .agent, body: "Which?", createdAt: Date(timeIntervalSince1970: 1),
                           actions: ["Docs", "Billing"], multiSelect: true),
        ])
        await sync.enqueueSelection(itemID: "it_1", localID: "L1", selected: ["Docs", "Billing"], body: "Docs, Billing", replyTo: "ic_ask")
        try await waitUntil { (try? store.itemOutboxPending().isEmpty) == true && !api.answers.isEmpty }
        XCTAssertEqual(api.answers.map(\.selected), [["Docs", "Billing"]])
        XCTAssertEqual(api.answers.first?.replyTo, "ic_ask")
        XCTAssertEqual(api.answers.first?.key, "L1", "the row's id is the idempotency key, as for a tap")
        let thread = try store.comments(itemID: "it_1")
        XCTAssertEqual(thread.first { $0.id == "ic_ask" }?.chosenActions, ["Docs", "Billing"])
        XCTAssertEqual(thread.first { $0.id == "ic_srv" }?.selected, ["Docs", "Billing"])
    }

    func testAnAnswerWhoseLabelsWereWithdrawnIsResentAsATypedReply() async throws {
        let api = AnsweringAPI(); api.refuseLabels = true
        let (sync, store) = try await makeSync(api)
        await sync.enqueueSelection(itemID: "it_1", localID: "L1", selected: ["Docs"], body: "Docs", replyTo: nil)
        try await waitUntil { (try? store.itemOutboxPending().isEmpty) == true && !api.typed.isEmpty }
        XCTAssertEqual(api.typed, ["Docs"], "the user's words still go")
    }
}

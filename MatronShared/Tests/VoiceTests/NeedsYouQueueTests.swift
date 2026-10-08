import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class NeedsYouQueueTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 10_000)
    static let permissionID = "0b6f4c3e-8a7d-4e21-9f2a-3c5d7e9a1b2c"

    static func promptRow(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10, title: String = "[ab] Auth refactor",
                          agent: String? = "aspen", payload: [String: Any]) -> UnansweredPromptRow {
        let event = JournalEvent(seq: seq, convoID: convo, ts: now.addingTimeInterval(-age), sender: "agent:aspen",
                                 type: "prompt", payloadData: try! JSONSerialization.data(withJSONObject: payload))
        return UnansweredPromptRow(event: event, convoTitle: title, agentName: agent)
    }

    static func ask(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10) -> UnansweredPromptRow {
        promptRow(seq, convo: convo, age: age, payload: ["question": "Which database?\nPick one.", "options": ["Postgres", "SQLite"]])
    }

    static func permission(_ seq: Int64, convo: String = "c1", age: TimeInterval = 10, tool: String = "Bash") -> UnansweredPromptRow {
        promptRow(seq, convo: convo, age: age, payload: [
            "question": "🔐 Permission: Claude wants to run \(tool)\ngit push origin main",
            "mode": "pick_one",
            "options": [
                ["id": "perm-allow", "label": "Allow once", "value": "perm:\(permissionID):allow"],
                ["id": "perm-always", "label": "Always allow \(tool) (session)", "value": "perm:\(permissionID):always"],
                ["id": "perm-deny", "label": "Deny", "value": "perm:\(permissionID):deny"],
            ],
        ])
    }

    static func item(_ id: String, num: Int, rank: Double, awaiting: ItemAwaiting? = .user, state: ItemState = .open,
                     convo: String = "c1", title: String? = nil) -> TrackerItem {
        TrackerItem(id: id, num: num, kind: .question, state: state, awaiting: awaiting, rank: rank,
                    title: title ?? "Item \(num)", originConvoID: convo)
    }

    static func convo(_ id: String, unread: Int = 1, state: String = "waiting", activity: TimeInterval = 100,
                      muted: Bool = false, title: String? = nil) -> QueueConversation {
        QueueConversation(id: id, title: title ?? "[\(id.prefix(2))] Chat \(id)", boxName: "aspen", unreadCount: unread,
                          sessionState: state, lastActivity: Date(timeIntervalSince1970: activity), muted: muted)
    }

    /// Spec §5: permissions, then prompts, then items in tracker order,
    /// then conversations with an unseen reply.
    func testOrderIsPermissionsPromptsItemsThenConversations() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.ask(7, convo: "c2"), Self.permission(9, convo: "c3"), Self.permission(8, convo: "c4")],
            items: [Self.item("it_b", num: 12, rank: 2048), Self.item("it_a", num: 30, rank: 1024),
                    Self.item("it_c", num: 5, rank: 1024)],
            conversations: [Self.convo("c8", activity: 100), Self.convo("c9", activity: 200)],
            now: Self.now)
        XCTAssertEqual(entries.map(\.id),
                       ["prompt:8", "prompt:9", "prompt:7", "item:it_c", "item:it_a", "item:it_b", "convo:c9", "convo:c8"])
    }

    func testTitlesAndConversationNames() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.permission(1), Self.permission(2, tool: "Edit"), Self.ask(3)],
            items: [Self.item("it_a", num: 1, rank: 1, title: "Pricing page copy")],
            conversations: [Self.convo("c1", unread: 0), Self.convo("c5", title: "[zz] Promo launch")],
            now: Self.now)
        XCTAssertEqual(entries.map(\.title), [
            "aspen wants to run a command", "aspen wants to use Edit", "Which database?", "Pricing page copy", "Promo launch",
        ])
        XCTAssertEqual(entries[0].convoTitle, "Auth refactor", "the session short is not said")
        XCTAssertEqual(entries[3].convoTitle, "Chat c1", "an item names its origin conversation")
        XCTAssertEqual(entries[3].boxName, "aspen")
        if case .permission(let prompt) = entries[0].kind {
            XCTAssertEqual(prompt.permission, VoicePrompt.Permission(tool: "Bash", detail: "git push origin main"))
            XCTAssertEqual(prompt.option(for: .deny)?.label, "Deny")
            XCTAssertEqual(prompt.option(for: .allow)?.value, "perm:\(Self.permissionID):allow")
        } else {
            XCTFail("the first entry is the permission prompt")
        }
    }

    /// A permission card is denied by the bridge after five minutes; an
    /// ask-user prompt stops being a question after a day.
    func testExpiredPromptsAreLeftOut() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.permission(1, age: 299), Self.permission(2, age: 300), Self.ask(3, age: 86_399), Self.ask(4, age: 86_400)],
            items: [], conversations: [], now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:1", "prompt:3"])
    }

    func testOnlyOpenItemsAwaitingTheUserCount() {
        let entries = NeedsYouQueue.build(prompts: [], items: [
            Self.item("it_a", num: 1, rank: 1, awaiting: .agent), Self.item("it_b", num: 2, rank: 2, awaiting: nil),
            Self.item("it_c", num: 3, rank: 3, state: .closed), Self.item("it_d", num: 4, rank: 4),
        ], conversations: [], now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["item:it_d"])
    }

    /// A reply is unseen when the conversation has unread messages and its
    /// turn has ended. Muted conversations are left alone, and one already
    /// in the queue for a prompt is not listed twice.
    func testWhichConversationsCountAsAnUnseenReply() {
        let entries = NeedsYouQueue.build(
            prompts: [Self.ask(3, convo: "asked")],
            items: [],
            conversations: [
                Self.convo("read", unread: 0), Self.convo("working", state: "running"), Self.convo("muted", muted: true),
                Self.convo("asked"), Self.convo("done", state: "done"), Self.convo("waiting"),
            ],
            now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:3", "convo:done", "convo:waiting"])
    }

    func testSummaryForSiri() {
        XCTAssertEqual(NeedsYouQueue.summary([]), "Nothing needs you.")
        let one = NeedsYouQueue.build(prompts: [], items: [Self.item("it_a", num: 1, rank: 1, title: "Approve the claims copy")],
                                      conversations: [], now: Self.now)
        XCTAssertEqual(NeedsYouQueue.summary(one), "One thing needs you. Approve the claims copy.")
        let several = NeedsYouQueue.build(prompts: [Self.permission(1)], items: [Self.item("it_a", num: 1, rank: 1)],
                                          conversations: [Self.convo("c9")], now: Self.now)
        XCTAssertEqual(NeedsYouQueue.summary(several), "Three things need you. The first: aspen wants to run a command.")
    }

    /// The store adapter: the same answer from a real mirror.
    func testStoreAdapterReadsTheMirror() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        func event(_ seq: Int64, convo: String, sender: String = "agent:aspen", type: String, payload: [String: Any]) -> JournalEvent {
            JournalEvent(seq: seq, convoID: convo, ts: Self.now.addingTimeInterval(-60), sender: sender, type: type,
                         payloadData: try! JSONSerialization.data(withJSONObject: payload))
        }
        _ = try store.applyJournalBatch([
            event(1, convo: "c1", type: "convo_meta", payload: ["title": "[ab] Auth refactor"]),
            event(2, convo: "c1", type: "text", payload: ["body": "Done."]),
            event(3, convo: "c1", type: "session_status", payload: ["state": "waiting"]),
            event(4, convo: "c2", type: "convo_meta", payload: ["title": "[cd] Promo"]),
            event(5, convo: "c2", type: "prompt", payload: ["question": "Ship it?", "options": ["Yes", "No"]]),
        ])
        try store.upsertItems([Self.item("it_a", num: 7, rank: 1, convo: "c1", title: "Pick a colour")])
        let entries = try store.needsYouEntries(now: Self.now)
        XCTAssertEqual(entries.map(\.id), ["prompt:5", "item:it_a", "convo:c1"])
        XCTAssertEqual(entries.map(\.title), ["Ship it?", "Pick a colour", "Auth refactor"])
    }
}

#if os(macOS)
import XCTest
@testable import MatronMac
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels

/// `MacSidebarChatList` (the AppKit sidebar's rows, groups and updates,
/// from the chat-list index) and `MacSidebarChatFeed` / `MacSidebarChatSource`
/// over a real store.
@MainActor
final class MacSidebarChatFeedTests: XCTestCase {
    var store: JournalStore!
    let now = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    /// The stream's next publication; fails if it ended.
    func take(_ iterator: inout AsyncStream<MacSidebarChatFeed.Publication>.Iterator) async throws
        -> MacSidebarChatFeed.Publication {
        let next = await iterator.next()
        return try XCTUnwrap(next, "the stream ended")
    }

    func ms(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

    /// A dozen conversations across every recency group, one with no
    /// activity time (its creation time stands in) and one with neither.
    func seed() throws {
        let startOfDay = Calendar.current.startOfDay(for: now)
        let sinceMidnight = now.timeIntervalSince(startOfDay)
        func today(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-min(seconds, max(0, sinceMidnight - 1))) }
        let day: TimeInterval = 86400
        let convos: [(String, String, Date?)] = [
            ("c1", "Quarterly planning notes", today(300)),
            ("c2", "Fix the flaky login test", today(720)),
            ("coord", "Coordinator", today(30)),
            ("desk", "Inbox triage", today(60)),
            ("c3", "Release checklist", today(3600)),
            ("c4", "Garden irrigation timer", startOfDay.addingTimeInterval(-3600)),
            ("c5", "Recipe scaler script", startOfDay.addingTimeInterval(-7200)),
            ("c6", "Photo library cleanup", startOfDay.addingTimeInterval(-3 * day)),
            ("c7", "Weekend trip itinerary", startOfDay.addingTimeInterval(-5 * day)),
            ("c8", "Old prototype ideas", now.addingTimeInterval(-40 * day)),
        ]
        var dtos = convos.enumerated().map { index, convo in
            ConvoSummaryDTO(id: convo.0, title: convo.1, sessionState: "idle", lastSeq: Int64(index),
                            snippet: "Snippet \(convo.0)", createdAt: ms(now.addingTimeInterval(-90 * day)),
                            lastTS: convo.2.map(ms))
        }
        // No activity time: the creation time is what the row shows.
        dtos.append(ConvoSummaryDTO(id: "c9", title: "Reading list", sessionState: "idle", lastSeq: 20,
                                    snippet: "", createdAt: ms(now.addingTimeInterval(-2 * day))))
        dtos.append(ConvoSummaryDTO(id: "c10", title: "Bird feeder camera", sessionState: "idle", lastSeq: 21,
                                    snippet: "Motion clips", createdAt: 0))
        try store.applyColdSnapshot(dtos, headSeq: 0)
    }

    func records() throws -> [ConversationRecord] { try store.conversations(now: now) }

    func reset(_ records: [ConversationRecord]) -> ListPublication<ConversationRecord, String> {
        ListPublication(update: .reset([ListSection(key: "chats", ids: records.map(\.id))]), rows: records)
    }

    /// What `ChatListViewModel` shows for the same rows: its groups' ids.
    func viewModelGroups(_ records: [ConversationRecord], hiding: String? = nil,
                         pinned: Set<String> = []) -> [ListSection<String>] {
        let summaries = records.map { JournalChatService.summary(from: $0, boxNames: [:]) }
        let groups = ChatListViewModel.partition(summaries, hiding: hiding, pinned: pinned).groups
        return groups.map { ListSection(key: $0.group.rawValue, ids: $0.summaries.map(\.id)) }
    }

    func nonEmpty(_ sections: [ListSection<String>]) -> [ListSection<String>] { sections.filter { !$0.ids.isEmpty } }

    // MARK: Rows, groups and order

    func test_firstPublish_isAReset_withChatListViewModelsGroupsAndOrder() throws {
        try seed()
        var list = MacSidebarChatList()
        list.setContext(MacSidebarChatContext(hiddenID: "coord", pinnedIDs: ["desk"]))
        let records = try records()
        list.take(reset(records))
        let publication = try XCTUnwrap(list.next(now: now))
        XCTAssertTrue(publication.update.isReset)
        XCTAssertEqual(publication.update.sections.map(\.key), MacSidebarChatList.sectionKeys,
                       "every group, always, so the keys never change")
        XCTAssertEqual(nonEmpty(publication.update.sections),
                       viewModelGroups(records, hiding: "coord", pinned: ["desk"]))
        XCTAssertEqual(publication.rows.map(\.id), publication.update.sections.flatMap(\.ids))
        XCTAssertFalse(publication.rows.contains { $0.id == "coord" || $0.id == "desk" })
        XCTAssertEqual(publication.rows.first { $0.id == "c9" }?.group, .lastSevenDays,
                       "no activity time: grouped by when it was created")
        XCTAssertEqual(publication.rows.first { $0.id == "c10" }?.group, .noActivity)
        XCTAssertNil(list.next(now: now), "nothing changed")
    }

    func test_contentChange_reconfiguresTheRowInPlace() throws {
        try seed()
        var list = MacSidebarChatList()
        let before = try records()
        list.take(reset(before))
        _ = list.next(now: now)

        // c3's snippet changes; its activity time does not.
        var dtos = before.map { r in
            ConvoSummaryDTO(id: r.id, title: r.title, sessionState: r.sessionState,
                            lastSeq: r.id == "c3" ? r.lastSeq + 100 : r.lastSeq,
                            snippet: r.id == "c3" ? "A new line" : r.snippet, createdAt: r.createdAt,
                            lastTS: r.lastActivityTS)
        }
        dtos.sort { $0.id < $1.id }
        try store.applyColdSnapshot(dtos, headSeq: 0)
        let after = try records()
        let update = ListUpdate(from: [ListSection(key: "chats", ids: before.map(\.id))],
                                to: [ListSection(key: "chats", ids: after.map(\.id))], touched: ["c3"])
        list.take(ListPublication(update: update, rows: after))
        let publication = try XCTUnwrap(list.next(now: now))
        XCTAssertFalse(publication.update.isReset)
        XCTAssertEqual(publication.update.reconfigured, ["c3"])
        XCTAssertTrue(publication.update.inserted.isEmpty && publication.update.removed.isEmpty)
        XCTAssertEqual(publication.rows.first { $0.id == "c3" }?.summary.snippet, "A new line")
    }

    func test_activity_movesTheRowAcrossGroups() throws {
        try seed()
        var list = MacSidebarChatList()
        let before = try records()
        list.take(reset(before))
        _ = list.next(now: now)

        // c8 (Earlier) gets a message now: it moves to the top of Today.
        let dtos = before.map { r in
            ConvoSummaryDTO(id: r.id, title: r.title, sessionState: r.sessionState, lastSeq: r.lastSeq,
                            snippet: r.snippet, createdAt: r.createdAt,
                            lastTS: r.id == "c8" ? ms(now) : r.lastActivityTS)
        }
        try store.applyColdSnapshot(dtos, headSeq: 0)
        let after = try records()
        let update = ListUpdate(from: [ListSection(key: "chats", ids: before.map(\.id))],
                                to: [ListSection(key: "chats", ids: after.map(\.id))], touched: ["c8"])
        list.take(ListPublication(update: update, rows: after))
        let publication = try XCTUnwrap(list.next(now: now))
        XCTAssertFalse(publication.update.isReset)
        XCTAssertEqual(publication.update.moved.count, 1)
        XCTAssertEqual(publication.update.sections[0].ids.first, "c8")
        XCTAssertEqual(nonEmpty(publication.update.sections), viewModelGroups(after))
    }

    func test_context_hidingPinningSilencingAndNew_editTheListWithoutAReset() throws {
        try seed()
        var list = MacSidebarChatList()
        list.take(reset(try records()))
        _ = list.next(now: now)

        list.setContext(MacSidebarChatContext(hiddenID: "coord", pinnedIDs: ["desk"], silencedIDs: ["c1"],
                                              newIDs: ["c2"]))
        let publication = try XCTUnwrap(list.next(now: now))
        XCTAssertFalse(publication.update.isReset)
        XCTAssertEqual(publication.update.removed.count, 2, "the Coordinator and the desk leave")
        XCTAssertEqual(Set(publication.update.reconfigured), ["c1", "c2"])
        XCTAssertEqual(publication.rows.first { $0.id == "c1" }?.isSilenced, true)
        XCTAssertEqual(publication.rows.first { $0.id == "c2" }?.isNew, true)

        list.setContext(MacSidebarChatContext(hiddenID: "coord", pinnedIDs: ["desk"]))
        let cleared = try XCTUnwrap(list.next(now: now))
        XCTAssertEqual(Set(cleared.update.reconfigured), ["c1", "c2"])
    }

    func test_needsYouCounts_andTheRoster_reachTheRows() throws {
        try seed()
        var list = MacSidebarChatList()
        list.take(reset(try records()))
        _ = list.next(now: now)

        list.setNeedsUser(["c5": 2])
        let needs = try XCTUnwrap(list.next(now: now))
        XCTAssertEqual(needs.update.reconfigured, ["c5"])
        XCTAssertEqual(needs.rows.first { $0.id == "c5" }?.summary.needsUserCount, 2)
        list.setNeedsUser([:])
        XCTAssertEqual(try XCTUnwrap(list.next(now: now)).rows.first { $0.id == "c5" }?.summary.needsUserCount, 0)

        // A roster that changes no row's chip publishes nothing.
        list.setRoster(names: [1: "box-a"], tagChars: [:])
        XCTAssertNil(list.next(now: now))
    }

    func test_beforeTheIndexAnswers_nothingIsPublished() {
        var list = MacSidebarChatList()
        list.setContext(MacSidebarChatContext(hiddenID: "coord"))
        XCTAssertNil(list.next(now: now))
    }

    func test_buckets_agreeWithChatRecencyGroup() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        var dates: [Date?] = [nil, now, now.addingTimeInterval(3600 * 30)]
        for hours in stride(from: -24 * 9, through: 24, by: 1) {
            dates.append(start.addingTimeInterval(TimeInterval(hours) * 3600))
            dates.append(start.addingTimeInterval(TimeInterval(hours) * 3600 - 1))
        }
        dates.append(calendar.date(byAdding: .day, value: -7, to: now)!)
        dates.append(calendar.date(byAdding: .day, value: -7, to: now)!.addingTimeInterval(-1))
        let buckets = MacRecencyBuckets(now: now, calendar: calendar)
        for date in dates {
            XCTAssertEqual(buckets.bucket(date), ChatRecencyGroup.bucket(date, now: now, calendar: calendar),
                           "\(String(describing: date))")
        }
    }

    // MARK: The feed over a real store

    func test_feed_publishesTheStoresChatList_thenItsChanges() async throws {
        try seed()
        let (contexts, contextContinuation) = AsyncStream<MacSidebarChatContext>.makeStream()
        contextContinuation.yield(MacSidebarChatContext(hiddenID: "coord"))
        let stream = MacSidebarChatFeed.publications(MacSidebarChatFeed.inputs(store: store, contexts: contexts))
        var iterator = stream.makeAsyncIterator()
        var first = try await take(&iterator)
        // The context may land after the first rows: take the newest.
        while first.rows.contains(where: { $0.id == "coord" }) { first = try await take(&iterator) }
        XCTAssertEqual(Set(first.rows.map(\.id)), Set(try records().map(\.id)).subtracting(["coord"]))

        try store.ensureConversation(id: "c11", title: "Brand new chat", now: now)
        var next = try await take(&iterator)
        while !next.rows.contains(where: { $0.id == "c11" }) { next = try await take(&iterator) }
        XCTAssertFalse(next.update.isReset, "an insert, not a reload")
        XCTAssertEqual(next.update.inserted.count, 1)
        contextContinuation.finish()
    }

    func test_source_sendsTheWindowsContext_andSaysWhenEmpty() async throws {
        try seed()
        let viewModel = ChatListViewModel(chat: SidebarFakeChatService())
        viewModel.hiddenConversationID = "coord"
        let source = MacSidebarChatSource(viewModel: viewModel, notifyStore: nil, store: store)
        XCTAssertNil(source.isEmpty)
        var iterator = source.publications().makeAsyncIterator()
        var publication = try await take(&iterator)
        while publication.rows.contains(where: { $0.id == "coord" }) {
            publication = try await take(&iterator)
        }
        XCTAssertEqual(source.isEmpty, false)
        XCTAssertEqual(source.context?.hiddenID, "coord")

        // The window pins a desk and marks a session new: the rows follow.
        viewModel.pinnedConversationIDs = ["desk"]
        viewModel.markNew("c2")
        while publication.rows.contains(where: { $0.id == "desk" })
                || publication.rows.first(where: { $0.id == "c2" })?.isNew != true {
            publication = try await take(&iterator)
        }
        XCTAssertEqual(source.context?.pinnedIDs, ["desk"])
        XCTAssertEqual(source.context?.newIDs, ["c2"])
        source.stop()
    }
}

/// A chat service with no chats (the source reads the view model's ids,
/// not its rows).
final class SidebarFakeChatService: ChatService, @unchecked Sendable {
    private let lock = NSLock()
    private var _archived: [[String]] = []
    var archived: [[String]] { lock.withLock { _archived } }

    func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> { AsyncThrowingStream { _ in } }
    func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> { AsyncStream { $0.finish() } }
    func createChat(with botID: String) async throws -> String { "c-new" }
    func refresh() async throws {}
    func forceSnapshot() async throws {}
    func mute(roomID: String) async throws {}
    func setArchived(_ roomIDs: [String], archived: Bool) async { lock.withLock { _archived.append(roomIDs) } }
}
#endif

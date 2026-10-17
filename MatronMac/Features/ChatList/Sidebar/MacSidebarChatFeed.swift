import Foundation
import MatronChat
import MatronJournal
import MatronModels

/// One row of the AppKit sidebar: what `MacChatListCell` draws. Everything
/// the row shows is in here, the notification bell-slash and the "New"
/// marker included, so a change to any of it is a content change the list
/// update names, and the host re-renders just that row.
struct MacSidebarChat: Identifiable, Equatable, Sendable {
    var summary: ChatSummary
    var group: ChatRecencyGroup
    /// Level None or a running mute: the bell-slash beside the badges.
    var isSilenced = false
    /// Arrived without the user starting it here, not opened since.
    var isNew = false

    var id: String { summary.id }
}

/// What the window decides beside the index's rows: which chats stay out of
/// the list (the Coordinator, the pinned desks) and the per-row state kept
/// by other models (notification settings, the "New" markers).
struct MacSidebarChatContext: Equatable, Sendable {
    var hiddenID: String?
    var pinnedIDs: Set<String> = []
    var silencedIDs: Set<String> = []
    var newIDs: Set<String> = []
}

/// `ChatRecencyGroup.bucket` for one instant, with the calendar work done
/// once rather than per row: the list buckets every row on each publish.
struct MacRecencyBuckets {
    let startOfToday: Date
    let startOfTomorrow: Date
    let startOfYesterday: Date
    let sevenDaysAgo: Date

    init(now: Date, calendar: Calendar = .current) {
        startOfToday = calendar.startOfDay(for: now)
        startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        startOfYesterday = calendar.startOfDay(for: yesterday)
        sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now) ?? now
    }

    /// The same answer as `ChatRecencyGroup.bucket(date, now:, calendar:)`.
    func bucket(_ date: Date?) -> ChatRecencyGroup {
        guard let date else { return .noActivity }
        if date >= startOfToday, date < startOfTomorrow { return .today }
        if date >= startOfYesterday, date < startOfToday { return .yesterday }
        return date >= sevenDaysAgo ? .lastSevenDays : .earlier
    }
}

/// The AppKit sidebar's list, derived from the chat-list index's
/// publications: the same rows, groups and order the SwiftUI sidebar draws
/// from `ChatListViewModel.groups` (the Coordinator and the pinned desks
/// left out, recency groups, newest first), published as `ListUpdate`s for
/// `MacListHost`.
///
/// A value type with no clock and no queue, so the tests drive it
/// synchronously; `MacSidebarChatFeed` runs it off the main actor.
///
/// Cost per publish: one pass over the index's rows (a dictionary lookup
/// and a date comparison each), a sort per group, and the linear
/// `ListUpdate` diff. A row's `ChatSummary` is re-made only when the index
/// names the row as changed, or the roster or its needs-you count changed.
struct MacSidebarChatList {
    /// Every section, in this order, always present (empty or not), so the
    /// section keys never change between updates; the host shows no header
    /// for an empty section.
    static let sectionKeys = ChatRecencyGroup.allCases.map(\.rawValue)

    private var records: [ConversationRecord] = []
    private var hasRecords = false
    private var summaries: [String: ChatSummary] = [:]
    /// Ids whose summary must be re-made before the next publish.
    private var stale: Set<String> = []
    private var remapAll = true

    private var boxNames: [Int64: String]?
    private var boxLetters: [Int64: String] = [:]
    private var needsUser: [String: Int] = [:]
    private(set) var context = MacSidebarChatContext()

    private var published: [ListSection<String>]?
    private var publishedRows: [String: MacSidebarChat] = [:]

    /// Whether a roster has been given (the feed reads one through when the
    /// first rows arrive before the roster stream's first value).
    var hasRoster: Bool { boxNames != nil }

    // MARK: Inputs

    /// The index's newest publication. Its update says which rows changed;
    /// only those are re-mapped.
    mutating func take(_ publication: ListPublication<ConversationRecord, String>) {
        records = publication.rows
        hasRecords = true
        let update = publication.update
        guard !update.isReset else {
            remapAll = true
            return
        }
        let sections = update.sections
        func id(_ path: ListPath) -> String? {
            guard sections.indices.contains(path.section), sections[path.section].ids.indices.contains(path.row)
            else { return nil }
            return sections[path.section].ids[path.row]
        }
        for path in update.inserted { if let id = id(path) { stale.insert(id) } }
        for move in update.moved { if let id = id(move.to) { stale.insert(id) } }
        stale.formUnion(update.reconfigured)
    }

    /// The agent roster: box names and their journal-held tag characters.
    mutating func setRoster(names: [Int64: String], tagChars: [Int64: String]) {
        let letters = SessionTag.boxLetters(for: names, overrides: tagChars)
        guard names != boxNames || letters != boxLetters else { return }
        boxNames = names
        boxLetters = letters
        remapAll = true
    }

    /// Open items awaiting the user, by origin conversation.
    mutating func setNeedsUser(_ counts: [String: Int]) {
        guard counts != needsUser else { return }
        for (id, count) in counts where needsUser[id] != count { stale.insert(id) }
        for id in needsUser.keys where counts[id] == nil { stale.insert(id) }
        needsUser = counts
    }

    mutating func setContext(_ context: MacSidebarChatContext) {
        self.context = context
    }

    // MARK: Publishing

    /// The update from the last published state to the list at `now`, with
    /// its rows; `nil` before the index's first rows, or when nothing the
    /// list shows changed. The first one is a reset.
    mutating func next(now: Date, calendar: Calendar = .current) -> ListPublication<MacSidebarChat, String>? {
        guard hasRecords else { return nil }
        remapSummaries()

        let buckets = MacRecencyBuckets(now: now, calendar: calendar)
        let context = context
        var groups = [[(row: MacSidebarChat, position: Int)]](repeating: [], count: ChatRecencyGroup.allCases.count)
        for (position, record) in records.enumerated() {
            let id = record.id
            if id == context.hiddenID || context.pinnedIDs.contains(id) { continue }
            guard let summary = summaries[id] else { continue }
            let group = buckets.bucket(summary.lastActivity)
            let row = MacSidebarChat(summary: summary, group: group, isSilenced: context.silencedIDs.contains(id),
                                     isNew: context.newIDs.contains(id))
            groups[Self.groupIndex(group)].append((row, position))
        }

        var sections: [ListSection<String>] = []
        sections.reserveCapacity(groups.count)
        var rows: [MacSidebarChat] = []
        rows.reserveCapacity(records.count)
        var shown: [String: MacSidebarChat] = [:]
        shown.reserveCapacity(records.count)
        var touched: Set<String> = []
        for (index, var group) in groups.enumerated() {
            group.sort(by: Self.byRecencyDescending)
            sections.append(ListSection(key: Self.sectionKeys[index], ids: group.map(\.row.id)))
            for (row, _) in group {
                rows.append(row)
                shown[row.id] = row
                if publishedRows[row.id] != row { touched.insert(row.id) }
            }
        }
        for id in publishedRows.keys where shown[id] == nil { touched.insert(id) }

        let update: ListUpdate<String>
        if let published {
            update = ListUpdate(from: published, to: sections, touched: touched)
            guard update.hasChanges else { return nil }
        } else {
            update = .reset(sections)
        }
        published = update.sections
        publishedRows = shown
        return ListPublication(update: update, rows: rows)
    }

    private mutating func remapSummaries() {
        let names = boxNames ?? [:]
        if remapAll {
            var fresh: [String: ChatSummary] = [:]
            fresh.reserveCapacity(records.count)
            for record in records {
                fresh[record.id] = JournalChatService.summary(from: record, boxNames: names, boxLetters: boxLetters,
                                                              needsUser: needsUser[record.id] ?? 0)
            }
            summaries = fresh
        } else if !stale.isEmpty {
            for record in records where stale.contains(record.id) {
                summaries[record.id] = JournalChatService.summary(
                    from: record, boxNames: names, boxLetters: boxLetters, needsUser: needsUser[record.id] ?? 0)
            }
            // Rows the index dropped linger here until the next full remap;
            // keep that bounded.
            if summaries.count > records.count * 2 + 64 { remapAll = true; remapSummaries() }
        }
        remapAll = false
        stale.removeAll(keepingCapacity: true)
    }

    private static func groupIndex(_ group: ChatRecencyGroup) -> Int {
        switch group {
        case .today: return 0
        case .yesterday: return 1
        case .lastSevenDays: return 2
        case .earlier: return 3
        case .noActivity: return 4
        }
    }

    /// `ChatListViewModel`'s order (newest first; rows with no activity by
    /// title), with the index's order breaking ties, so the order is total
    /// and an unchanged row keeps its place among the other unchanged rows.
    private static func byRecencyDescending(_ a: (row: MacSidebarChat, position: Int),
                                            _ b: (row: MacSidebarChat, position: Int)) -> Bool {
        switch (a.row.summary.lastActivity, b.row.summary.lastActivity) {
        case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil) where a.row.summary.title != b.row.summary.title:
            return a.row.summary.title < b.row.summary.title
        default: return a.position < b.position
        }
    }
}

/// Runs `MacSidebarChatList` off the main actor over its input streams and
/// publishes its updates as a stream for `MacListView`.
enum MacSidebarChatFeed {
    typealias Roster = (names: [Int64: String], tagChars: [Int64: String])
    typealias Publication = ListPublication<MacSidebarChat, String>

    struct Inputs: Sendable {
        /// The chat-list index (`JournalStore.chatListUpdatesStream()`).
        var publications: AsyncStream<ListPublication<ConversationRecord, String>>
        var roster: AsyncStream<Roster>
        var needsUser: AsyncStream<[String: Int]>
        var contexts: AsyncStream<MacSidebarChatContext>
        /// The context as it stands when the feed starts, set before any
        /// rows arrive so the first paint already hides and pins what the
        /// window says (`contexts` then carries only its changes).
        var initialContext: MacSidebarChatContext?
        /// Read when the first rows arrive before the roster stream's first
        /// value, so the first paint carries its box tags.
        var initialRoster: @Sendable () -> Roster
        /// How often the groups are re-checked with no input (a row passing
        /// midnight or the seven-day line changes group with no write).
        var regroupInterval: Duration = .seconds(60)
    }

    /// The feed's state, confined to this actor.
    private actor Driver {
        private var list = MacSidebarChatList()
        private let continuation: AsyncStream<Publication>.Continuation
        private let initialRoster: @Sendable () -> Roster

        init(continuation: AsyncStream<Publication>.Continuation, initialRoster: @escaping @Sendable () -> Roster,
             initialContext: MacSidebarChatContext?) {
            self.continuation = continuation
            self.initialRoster = initialRoster
            if let initialContext { list.setContext(initialContext) }
        }

        func take(_ publication: ListPublication<ConversationRecord, String>) {
            if !list.hasRoster {
                let roster = initialRoster()
                list.setRoster(names: roster.names, tagChars: roster.tagChars)
            }
            list.take(publication)
            publish()
        }

        func setRoster(_ roster: Roster) {
            list.setRoster(names: roster.names, tagChars: roster.tagChars)
            publish()
        }

        func setNeedsUser(_ counts: [String: Int]) {
            list.setNeedsUser(counts)
            publish()
        }

        func setContext(_ context: MacSidebarChatContext) {
            guard context != list.context else { return }
            list.setContext(context)
            publish()
        }

        func publish() {
            if let publication = list.next(now: Date()) { continuation.yield(publication) }
        }
    }

    static func publications(_ inputs: Inputs) -> AsyncStream<Publication> {
        AsyncStream { continuation in
            let driver = Driver(continuation: continuation, initialRoster: inputs.initialRoster,
                                initialContext: inputs.initialContext)
            let records = Task {
                for await publication in inputs.publications { await driver.take(publication) }
                // The index went away (sign-out): so does the list.
                continuation.finish()
            }
            let roster = Task { for await value in inputs.roster { await driver.setRoster(value) } }
            let needs = Task { for await value in inputs.needsUser { await driver.setNeedsUser(value) } }
            let contexts = Task { for await value in inputs.contexts { await driver.setContext(value) } }
            let interval = inputs.regroupInterval
            let regroup = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled else { return }
                    await driver.publish()
                }
            }
            continuation.onTermination = { _ in
                records.cancel()
                roster.cancel()
                needs.cancel()
                contexts.cancel()
                regroup.cancel()
            }
        }
    }

    /// The inputs for `store`'s chat list.
    static func inputs(store: JournalStore, contexts: AsyncStream<MacSidebarChatContext>,
                       initialContext: MacSidebarChatContext? = nil) -> Inputs {
        Inputs(publications: store.chatListUpdatesStream(),
               roster: store.agentRosterStream(),
               needsUser: store.needsUserCountsStream(),
               contexts: contexts,
               initialContext: initialContext,
               initialRoster: { ((try? store.agentNames()) ?? [:], (try? store.agentTagChars()) ?? [:]) })
    }
}

import Foundation
import MatronSearch
import MatronChat
import MatronModels
import MatronJournal

/// What the command palette can search besides conversations and messages:
/// the tracker rows this device holds. Read once when the palette opens
/// and filtered in memory as the query changes.
public struct CommandPaletteCatalog: Sendable {
    public var items: [TrackerItem]
    public var missions: [Mission]
    public var projects: [Project]

    public init(items: [TrackerItem] = [], missions: [Mission] = [], projects: [Project] = []) {
        self.items = items; self.missions = missions; self.projects = projects
    }

    public static let empty = CommandPaletteCatalog()
}

/// One row in the command palette.
public enum CommandPaletteResult: Identifiable, Sendable {
    /// What a bare number (`412`, `#412`) names, found locally or by the
    /// journal's lookup.
    case number(GoToNumberHit)
    case chat(ChatSummary)
    case item(TrackerItem)
    case mission(Mission)
    case project(Project)
    /// One conversation's message matches, from the journal's full-text
    /// search.
    case message(SearchChatHit)

    public var id: String {
        switch self {
        case .number(let hit): return "number:\(hit.num)"
        case .chat(let chat): return "chat:\(chat.id)"
        case .item(let item): return "item:\(item.id)"
        case .mission(let mission): return "mission:\(mission.id)"
        case .project(let project): return "project:\(project.id)"
        case .message(let hit): return "message:\(hit.roomID)"
        }
    }
}

/// A titled group of rows, in the order the palette shows them.
public struct CommandPaletteSection: Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case number, recent, chats, items, missions, projects, messages
    }

    public let kind: Kind
    public let results: [CommandPaletteResult]
    public var id: String { kind.rawValue }

    public var title: String {
        switch kind {
        case .number: return "Go to"
        case .recent: return "Recent conversations"
        case .chats: return "Conversations"
        case .items: return "Items"
        case .missions: return "Missions"
        case .projects: return "Projects"
        case .messages: return "Messages"
        }
    }
}

/// Drives the app-wide search palette: one field over conversations
/// (titles and pinned names), tracker items, missions and projects (by
/// number or words), and message text through the journal's full-text
/// search. Groups the results by kind and keeps a keyboard selection that
/// the arrow keys move and Return opens.
///
/// Conversations, messages and the number row come from a
/// `SearchViewModel` of its own, so the palette ranks and resolves them
/// exactly as the sidebar search does without taking over its query.
@Observable
@MainActor
public final class CommandPaletteViewModel: Identifiable {
    /// What is typed. Re-filters the tracker rows at once; `search()`
    /// (keyed on it) asks the journal after a typing pause.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            search.query = query
            refilter()
        }
    }

    /// The highlighted row, by `CommandPaletteResult.id`. Kept on the same
    /// row while results arrive around it; otherwise the first row.
    public private(set) var selectedID: String?

    public let search: SearchViewModel
    private var index = PaletteIndex(.empty)
    private let loadCatalog: @Sendable () async -> CommandPaletteCatalog
    /// Pinned conversations' sidebar names, by conversation id.
    private var pinLabels: [String: String]
    private var trackerMatches = TrackerMatches()
    /// Worked out when the query or the chat list changes, not each time
    /// the results are drawn.
    private(set) var chatMatches: [ChatSummary] = []

    /// Rows per section, so one kind with many matches does not push the
    /// others out of sight.
    static let chatLimit = 6
    static let recentLimit = 8
    static let itemLimit = 8
    static let missionLimit = 6
    static let projectLimit = 5
    static let messageLimit = 12
    /// One more than shown: the row the number row names is left out.
    static let trackerKeep = (items: itemLimit + 1, missions: missionLimit + 1, projects: projectLimit + 1)

    /// - Parameters:
    ///   - search: conversations, messages and the number row.
    ///   - pinLabels: the user's names for pinned conversations, which
    ///     find them as their titles do.
    ///   - loadCatalog: the items, missions and projects to filter, read
    ///     off the main actor when the palette opens.
    public init(search: SearchViewModel, pinLabels: [String: String] = [:],
                loadCatalog: @escaping @Sendable () async -> CommandPaletteCatalog) {
        self.search = search
        self.pinLabels = pinLabels
        self.loadCatalog = loadCatalog
        reselect()
    }

    /// Reads the tracker rows. Call once as the palette appears.
    public func load() async {
        let catalog = loadCatalog
        // Folding thousands of item bodies is the slow part of a keystroke,
        // so it is done once, here, off the main actor.
        index = await Task.detached(priority: .userInitiated) { PaletteIndex(await catalog()) }.value
        trackerMatches = index.match(PaletteTextFilter(query), keep: Self.trackerKeep)
        // Tracker rows land above anything typed for meanwhile: the
        // highlight goes to the top, as it does for a new query.
        selectedID = results.first?.id
    }

    /// Runs the message search and number lookup for the current query.
    /// Call it from a task keyed on the query, like `SearchViewModel.search()`.
    public func runSearch() async {
        let shownNumber = search.numberHit?.num
        await search.search()
        // A number is typed to go to it: its row takes the highlight when
        // it arrives, over whatever matched the digits as text meanwhile.
        if let hit = search.numberHit, hit.num != shownNumber {
            selectedID = CommandPaletteResult.number(hit).id
        } else {
            reselect()
        }
    }

    // MARK: Sections

    public var sections: [CommandPaletteSection] {
        var out: [CommandPaletteSection] = []
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let recent = search.allChats.filter { $0.parentConvoID == nil }
                .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
                .prefix(Self.recentLimit)
            if !recent.isEmpty { out.append(.init(kind: .recent, results: recent.map(CommandPaletteResult.chat))) }
            return out
        }
        let numberHit = search.numberHit
        if let numberHit { out.append(.init(kind: .number, results: [.number(numberHit)])) }
        // Tracker rows first: they are fewer and less noisy than
        // conversation titles.
        // The number row already opens what it names.
        func notTheNumber(_ num: Int) -> Bool { numberHit?.num != num }
        let items = trackerMatches.items.filter { notTheNumber($0.num) }.prefix(Self.itemLimit)
        if !items.isEmpty { out.append(.init(kind: .items, results: items.map(CommandPaletteResult.item))) }
        let missions = trackerMatches.missions.filter { notTheNumber($0.num) }.prefix(Self.missionLimit)
        if !missions.isEmpty { out.append(.init(kind: .missions, results: missions.map(CommandPaletteResult.mission))) }
        let projects = trackerMatches.projects.filter { notTheNumber($0.num) }.prefix(Self.projectLimit)
        if !projects.isEmpty { out.append(.init(kind: .projects, results: projects.map(CommandPaletteResult.project))) }
        let chats = chatMatches.prefix(Self.chatLimit)
        if !chats.isEmpty { out.append(.init(kind: .chats, results: chats.map(CommandPaletteResult.chat))) }
        let messages = search.messageHits.prefix(Self.messageLimit)
        if !messages.isEmpty { out.append(.init(kind: .messages, results: messages.map(CommandPaletteResult.message))) }
        return out
    }

    /// Every row, top to bottom: what the arrow keys step through.
    public var results: [CommandPaletteResult] { sections.flatMap(\.results) }

    public var selectedResult: CommandPaletteResult? {
        let all = results
        return all.first { $0.id == selectedID } ?? all.first
    }

    /// Nothing to show for a typed query, once every search has answered.
    public var showsNoResults: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && results.isEmpty && !search.isSearching
    }

    /// The line shown when nothing matched.
    public var emptyMessage: String {
        search.searchFailed ? search.emptyResultsMessage : "No results."
    }

    /// The sidebar search's chat matches, plus pinned conversations whose
    /// pin name matches, in chat-list order.
    private func matchChats() {
        let filter = PaletteTextFilter(query)
        guard filter.isActive else { chatMatches = []; return }
        let byTitle = Set(search.chatHits.map(\.id))
        chatMatches = search.allChats.filter { chat in
            byTitle.contains(chat.id) || pinLabels[chat.id].map { filter.matches([$0]) } == true
        }
    }

    // MARK: Selection

    /// Moves the highlight by `delta` rows, stopping at either end.
    public func moveSelection(by delta: Int) {
        let all = results
        guard !all.isEmpty else { selectedID = nil; return }
        let current = all.firstIndex { $0.id == selectedID } ?? 0
        let next = min(max(current + delta, 0), all.count - 1)
        selectedID = all[next].id
    }

    public func select(_ result: CommandPaletteResult) {
        selectedID = result.id
    }

    /// Keeps the highlight on its row while it is still listed, else puts
    /// it on the first.
    private func reselect() {
        let all = results
        if let selectedID, all.contains(where: { $0.id == selectedID }) { return }
        selectedID = all.first?.id
    }

    public func updateChats(_ chats: [ChatSummary], pinLabels: [String: String]) {
        search.updateChats(chats)
        self.pinLabels = pinLabels
        matchChats()
        reselect()
    }

    // MARK: Tracker filtering

    struct TrackerMatches {
        var items: [TrackerItem] = []
        var missions: [Mission] = []
        var projects: [Project] = []
    }

    private func refilter() {
        trackerMatches = index.match(PaletteTextFilter(query), keep: Self.trackerKeep)
        matchChats()
        // A new query starts at the top.
        selectedID = results.first?.id
    }

    /// The rows every word of the query is found in, ranked as
    /// `PaletteIndex.match` ranks them.
    static func match(_ filter: PaletteTextFilter, in catalog: CommandPaletteCatalog) -> TrackerMatches {
        PaletteIndex(catalog).match(filter)
    }
}

/// The catalog's searchable text, folded once when the palette opens.
/// Matching a keystroke then only looks for the query's words; while the
/// query only grows (the usual case when typing), it looks among the rows
/// the previous query matched rather than the whole catalog.
final class PaletteIndex: @unchecked Sendable {
    struct Entry<Row> {
        let row: Row
        /// Title, number, labels or short name, folded and as UTF-8:
        /// matches here rank first.
        let head: [[UInt8]]
        let body: [UInt8]
        let open: Bool
        let updated: Date
    }

    let items: [Entry<TrackerItem>]
    let missions: [Entry<Mission>]
    let projects: [Entry<Project>]

    /// The last query's words and the rows (by position) it matched.
    private var narrowed: (terms: [String], items: [Int], missions: [Int], projects: [Int])?

    init(_ catalog: CommandPaletteCatalog) {
        func fold(_ text: String) -> [UInt8] { Array(PaletteTextFilter.fold(text).utf8) }
        items = catalog.items.map {
            Entry(row: $0, head: ([$0.title, "#\($0.num)"] + $0.labels).map(fold), body: fold($0.body),
                  open: $0.state == .open, updated: $0.updatedAt)
        }
        missions = catalog.missions.map {
            Entry(row: $0, head: [$0.title, $0.name ?? "", "#\($0.num)"].map(fold), body: fold($0.body),
                  open: $0.state == .open, updated: $0.updatedAt)
        }
        projects = catalog.projects.map {
            Entry(row: $0, head: [$0.title, "#\($0.num)"].map(fold), body: fold($0.body),
                  open: $0.state == .open, updated: $0.updatedAt)
        }
    }

    /// Title (and number, labels or short name) matches come first, then
    /// those found only in the body; open before closed; newest first
    /// within that.
    /// - Parameter keep: how many of each kind to return, best first.
    func match(_ filter: PaletteTextFilter,
               keep: (items: Int, missions: Int, projects: Int) = (.max, .max, .max)) -> CommandPaletteViewModel.TrackerMatches {
        guard filter.isActive else { narrowed = nil; return .init() }
        let terms = filter.terms
        let needles = terms.map { Array($0.utf8) }
        // Every earlier word still inside one of the new words: nothing the
        // earlier query missed can match the new one.
        let refines = narrowed.map { old in
            old.terms.allSatisfy { term in terms.contains { $0.contains(term) } }
        } ?? false
        func found<Row>(_ entries: [Entry<Row>], among previous: [Int]?) -> [Int] {
            let candidates = previous ?? Array(entries.indices)
            return candidates.filter { i in
                let entry = entries[i]
                return needles.allSatisfy { needle in
                    entry.head.contains { Self.find(needle, in: $0) } || Self.find(needle, in: entry.body)
                }
            }
        }
        let next = (terms: terms,
                    items: found(items, among: refines ? narrowed?.items : nil),
                    missions: found(missions, among: refines ? narrowed?.missions : nil),
                    projects: found(projects, among: refines ? narrowed?.projects : nil))
        narrowed = next
        // Only the best few of each kind are shown, so they are picked out
        // rather than sorting every match: a short query matches most rows.
        func ranked<Row>(_ entries: [Entry<Row>], _ hits: [Int], keep: Int) -> [Row] {
            var best: [(rank: Int, updated: Date, row: Row)] = []
            best.reserveCapacity(min(keep, hits.count) + 1)
            func before(_ a: (rank: Int, updated: Date, row: Row), _ b: (rank: Int, updated: Date, row: Row)) -> Bool {
                a.rank != b.rank ? a.rank < b.rank : a.updated > b.updated
            }
            for i in hits {
                let entry = entries[i]
                let inHead = needles.allSatisfy { needle in entry.head.contains { Self.find(needle, in: $0) } }
                let candidate = (rank: (inHead ? 0 : 2) + (entry.open ? 0 : 1), updated: entry.updated, row: entry.row)
                if best.count == keep, let last = best.last, !before(candidate, last) { continue }
                let at = best.firstIndex { before(candidate, $0) } ?? best.endIndex
                best.insert(candidate, at: at)
                if best.count > keep { best.removeLast() }
            }
            return best.map(\.row)
        }
        return .init(items: ranked(items, next.items, keep: keep.items),
                     missions: ranked(missions, next.missions, keep: keep.missions),
                     projects: ranked(projects, next.projects, keep: keep.projects))
    }

    /// Whether `needle` occurs in `haystack`, byte for byte. Both are
    /// folded already, so this is the filter's substring rule without
    /// `String`'s per-character Unicode work, which made each keystroke
    /// slow over thousands of item bodies.
    static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Bool {
        guard !needle.isEmpty else { return true }
        guard needle.count <= haystack.count else { return false }
        return needle.withUnsafeBytes { n in
            haystack.withUnsafeBytes { h in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }
}

/// Every word of the query, found in any of the texts, ignoring case and
/// accents — the Projects filter's rule. A bare number also matches the
/// `#N` text it is searched against, so it finds that row by number.
struct PaletteTextFilter {
    let terms: [String]

    init(_ query: String) {
        terms = query.split(whereSeparator: \.isWhitespace).map { Self.fold(String($0)) }
    }

    var isActive: Bool { !terms.isEmpty }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    func matches(_ texts: [String]) -> Bool {
        let folded = texts.map(Self.fold)
        return terms.allSatisfy { term in
            folded.contains { $0.contains(term) }
        }
    }
}

public extension CommandPaletteViewModel {
    /// The production catalog: every item, mission and project in the
    /// session's local journal mirror, read off the main actor. A failed
    /// read searches nothing of that kind rather than failing the palette.
    static func catalogLoader(store: JournalStore) -> @Sendable () async -> CommandPaletteCatalog {
        {
            await Task.detached(priority: .userInitiated) {
                CommandPaletteCatalog(items: (try? store.items(scope: .all)) ?? [],
                                      missions: (try? store.missions(state: nil)) ?? [],
                                      projects: (try? store.projects()) ?? [])
            }.value
        }
    }
}

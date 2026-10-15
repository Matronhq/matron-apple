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
    private var catalog: CommandPaletteCatalog = .empty
    private let loadCatalog: @Sendable () async -> CommandPaletteCatalog
    /// Pinned conversations' sidebar names, by conversation id.
    private var pinLabels: [String: String]
    private var trackerMatches = TrackerMatches()

    /// Rows per section, so one kind with many matches does not push the
    /// others out of sight.
    static let chatLimit = 6
    static let recentLimit = 8
    static let itemLimit = 8
    static let missionLimit = 6
    static let projectLimit = 5
    static let messageLimit = 12

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
        catalog = await loadCatalog()
        trackerMatches = Self.match(PaletteTextFilter(query), in: catalog)
        reselect()
    }

    /// Runs the message search and number lookup for the current query.
    /// Call it from a task keyed on the query, like `SearchViewModel.search()`.
    public func runSearch() async {
        let hadNumber = search.numberHit != nil
        await search.search()
        // A number is typed to go to it: its row takes the highlight when
        // it arrives, over whatever matched the digits as text meanwhile.
        if !hadNumber, let hit = search.numberHit {
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
        let chats = chatMatches.prefix(Self.chatLimit)
        if !chats.isEmpty { out.append(.init(kind: .chats, results: chats.map(CommandPaletteResult.chat))) }
        // The number row already opens what it names.
        func notTheNumber(_ num: Int) -> Bool { numberHit?.num != num }
        let items = trackerMatches.items.filter { notTheNumber($0.num) }.prefix(Self.itemLimit)
        if !items.isEmpty { out.append(.init(kind: .items, results: items.map(CommandPaletteResult.item))) }
        let missions = trackerMatches.missions.filter { notTheNumber($0.num) }.prefix(Self.missionLimit)
        if !missions.isEmpty { out.append(.init(kind: .missions, results: missions.map(CommandPaletteResult.mission))) }
        let projects = trackerMatches.projects.filter { notTheNumber($0.num) }.prefix(Self.projectLimit)
        if !projects.isEmpty { out.append(.init(kind: .projects, results: projects.map(CommandPaletteResult.project))) }
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
    var chatMatches: [ChatSummary] {
        let byTitle = Set(search.chatHits.map(\.id))
        let filter = PaletteTextFilter(query)
        guard filter.isActive else { return [] }
        return search.allChats.filter { chat in
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
        reselect()
    }

    // MARK: Tracker filtering

    struct TrackerMatches {
        var items: [TrackerItem] = []
        var missions: [Mission] = []
        var projects: [Project] = []
    }

    private func refilter() {
        trackerMatches = Self.match(PaletteTextFilter(query), in: catalog)
        // A new query starts at the top.
        selectedID = results.first?.id
    }

    /// The rows every word of the query is found in. Title (and number,
    /// labels or short name) matches come first, then those found only in
    /// the body; open before closed; newest first within that.
    static func match(_ filter: PaletteTextFilter, in catalog: CommandPaletteCatalog) -> TrackerMatches {
        guard filter.isActive else { return TrackerMatches() }
        func ranked<T>(_ rows: [T], open: (T) -> Bool, updated: (T) -> Date,
                       head: (T) -> [String], body: (T) -> [String]) -> [T] {
            rows.compactMap { row -> (T, Int)? in
                let tier: Int
                if filter.matches(head(row)) { tier = 0 }
                else if filter.matches(head(row) + body(row)) { tier = 1 }
                else { return nil }
                return (row, tier * 2 + (open(row) ? 0 : 1))
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : updated($0.0) > updated($1.0) }
            .map(\.0)
        }
        return TrackerMatches(
            items: ranked(catalog.items, open: { $0.state == .open }, updated: \.updatedAt,
                          head: { [$0.title, "#\($0.num)"] + $0.labels }, body: { [$0.body] }),
            missions: ranked(catalog.missions, open: { $0.state == .open }, updated: \.updatedAt,
                             head: { [$0.title, $0.name ?? "", "#\($0.num)"] }, body: { [$0.body] }),
            projects: ranked(catalog.projects, open: { $0.state == .open }, updated: \.updatedAt,
                             head: { [$0.title, "#\($0.num)"] }, body: { [$0.body] }))
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

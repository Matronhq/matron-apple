import Foundation
import MatronSearch
import MatronChat
import MatronModels
import MatronJournal

/// Drives the unified search UI on both iOS and Mac. Owns the query string, the
/// FTS message hits, and the chat (title/bot) hits derived from a chat-list
/// snapshot.
@Observable
@MainActor
public final class SearchViewModel {
    public var query: String = ""
    /// Message results grouped one-per-conversation (match count + the top
    /// hit's snippet). A flat per-message list drowned every other chat the
    /// moment the query was a common word (Dan, 2026-08-26); drilling into a
    /// chat's individual matches is the in-conversation search's job.
    ///
    /// Ordered for the reader, not the index (Dan, 2026-10-02): chats
    /// holding the exact phrase first, and within that the chats in the
    /// chat list ahead of subagent chats — those are 71% of the indexed
    /// messages on Dan's Mac and almost never what is being looked for.
    /// Newest first within each.
    public private(set) var messageHits: [SearchChatHit] = []
    public private(set) var isSearching = false
    /// The last search could not be run (the index is shut while the device
    /// is locked, or it threw). Reported as such rather than as "No
    /// results", which reads as "you never said that".
    public private(set) var searchFailed = false

    public private(set) var allChats: [ChatSummary]
    private let search: SearchService
    private let ownSender: String?
    private let debounce: Duration
    private let lookupConversation: ConversationLookup?
    /// Conversations a hit named that the chat-list snapshot doesn't hold —
    /// subagent chats, mostly — resolved through `lookupConversation`.
    private var resolved: [String: ConversationInfo] = [:]
    /// Bumped by every `search()`; a run only publishes while it is still
    /// the latest, so a slow query for "ti" can't overwrite "time crisis".
    private var generation = 0

    /// Rows shown. More are fetched than shown (`candidateLimit`) so that
    /// reordering can't starve the list of chat-list conversations.
    static let resultLimit = 50
    static let candidateLimit = 200

    /// What the row needs to name a conversation that isn't in the chat
    /// list: its own title, and its parent when it is a subagent chat.
    public struct ConversationInfo: Equatable, Sendable {
        public let title: String
        public let parentID: String?

        public init(title: String, parentID: String?) {
            self.title = title; self.parentID = parentID
        }
    }

    public typealias ConversationLookup = @Sendable (_ convoID: String) async -> ConversationInfo?

    /// - Parameters:
    ///   - ownSender: this user's journal sender (`user:<id>`), so their own
    ///     messages read "You".
    ///   - debounce: how long typing must pause before the index is asked.
    ///     A query per keystroke queued a search for every prefix of the
    ///     word, each slower than the last one typed.
    ///   - lookupConversation: resolves conversations outside `allChats`.
    public init(search: SearchService, allChats: [ChatSummary], ownSender: String? = nil,
                debounce: Duration = .milliseconds(200),
                lookupConversation: ConversationLookup? = nil) {
        self.search = search
        self.allChats = allChats
        self.ownSender = ownSender
        self.debounce = debounce
        self.lookupConversation = lookupConversation
    }

    /// Refreshes the chat-list snapshot backing chat-title hits and
    /// `chatTitle(for:)`. The Mac search VM is long-lived (built once, lives in
    /// the window toolbar), so it must track later chat-list updates — new
    /// rooms, renamed titles — instead of clinging to the first snapshot
    /// (bugbot "Mac chat search snapshot stale"). On iOS the VM is rebuilt per
    /// sheet presentation, so it already sees a fresh snapshot; calling this is
    /// harmless there.
    public func updateChats(_ chats: [ChatSummary]) {
        allChats = chats
    }

    public var chatHits: [ChatSummary] {
        guard !query.isEmpty else { return [] }
        let lower = query.lowercased()
        return allChats.filter {
            $0.title.lowercased().contains(lower)
                || $0.bot.displayName.lowercased().contains(lower)
                || tagMatches($0, query: lower)
        }
    }

    /// Whether `lower` (the already-lowercased query) matches the chat's
    /// visible session tag in any of its rendered spellings
    /// (`SessionTag.searchSpellings`): the bare short (`b5`) or the
    /// letters:short form (`Y:b5`, `Y↔Z:ab`). The short is peeled out of the
    /// stored title (`SessionTag.splitTitle`), so without this clause a tag
    /// the user can SEE in the row would not find its chat (ported from
    /// matron-android#46). A query that IS a bare box letter deliberately
    /// never matches — one letter would light up every chat on that box and
    /// drown the real hits.
    private func tagMatches(_ chat: ChatSummary, query lower: String) -> Bool {
        let letters = chat.roomBoxShorts.count >= 2
            ? chat.roomBoxShorts : [chat.boxShort].compactMap { $0 }
        guard !letters.contains(where: { $0.lowercased() == lower }) else { return false }
        return SessionTag.searchSpellings(
            boxLetter: chat.boxShort,
            sessionShort: chat.sessionShort,
            roomBoxShorts: chat.roomBoxShorts
        ).contains { $0.lowercased().contains(lower) }
    }

    /// Resolves a room ID to its display title using `allChats`, then the
    /// conversations looked up for earlier hits. Never the raw room ID: a
    /// subagent chat's id is `<uuid>:sub:<agent id>`, which is what 87% of
    /// the indexed conversations showed as their name.
    public func chatTitle(for roomID: String) -> String {
        allChats.first(where: { $0.id == roomID })?.title
            ?? resolved[roomID]?.title
            ?? Self.unknownConversationTitle
    }

    static let unknownConversationTitle = "Unknown conversation"

    /// Row-ready pieces of a search hit's title line: the colored `A:bc`
    /// tag halves plus the title to sit beside them, resolved HERE so the
    /// iOS and Mac call sites compose identically (the row itself lives in
    /// the design system, which by design knows nothing of ChatSummary or
    /// the bridge's title markers).
    public struct HitTitle {
        public let title: String
        /// The subagent chat the hit is in, when it is in one; `title` and
        /// the tag are then its parent's, so the row reads
        /// "Parent chat › Subagent task".
        public let subChatTitle: String?
        public let sessionShort: String?
        public let boxLetter: String?
        public let boxName: String?
        public let roomBoxNames: [String]
        public let roomBoxShorts: [String]
    }

    public func hitTitle(for roomID: String) -> HitTitle {
        if let chat = allChats.first(where: { $0.id == roomID }) {
            return hitTitle(for: chat, subChatTitle: nil)
        }
        guard let info = resolved[roomID] else {
            return HitTitle(title: Self.unknownConversationTitle, subChatTitle: nil, sessionShort: nil,
                            boxLetter: nil, boxName: nil, roomBoxNames: [], roomBoxShorts: [])
        }
        guard let parentID = info.parentID else {
            return HitTitle(title: info.title, subChatTitle: nil, sessionShort: nil,
                            boxLetter: nil, boxName: nil, roomBoxNames: [], roomBoxShorts: [])
        }
        if let parent = allChats.first(where: { $0.id == parentID }) {
            return hitTitle(for: parent, subChatTitle: info.title)
        }
        return HitTitle(title: resolved[parentID]?.title ?? Self.unknownConversationTitle,
                        subChatTitle: info.title, sessionShort: nil,
                        boxLetter: nil, boxName: nil, roomBoxNames: [], roomBoxShorts: [])
    }

    private func hitTitle(for chat: ChatSummary, subChatTitle: String?) -> HitTitle {
        // Same marker discipline as the list rows: the room marker drops
        // only when a room tag will actually render in its place.
        let title = chat.roomBoxNames.count >= 2
            ? SessionTag.titleBesideRoomTag(chat.title) : chat.title
        return HitTitle(title: title, subChatTitle: subChatTitle, sessionShort: chat.sessionShort,
                        boxLetter: chat.boxShort, boxName: chat.boxName,
                        roomBoxNames: chat.roomBoxNames, roomBoxShorts: chat.roomBoxShorts)
    }

    /// Who wrote a hit, for the start of its preview line: "You" for this
    /// user, otherwise the name after the journal's `user:` / `agent:`
    /// prefix (an agent's is its box). `nil` for a sender in neither form.
    public func senderLabel(for hit: SearchHit) -> String? {
        if let ownSender, hit.sender == ownSender { return "You" }
        for prefix in ["user:", "agent:"] where hit.sender.hasPrefix(prefix) {
            let name = String(hit.sender.dropFirst(prefix.count))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Text to display when the query has no chat or message hits.
    public var emptyResultsMessage: String {
        if searchFailed { return "Search isn't available right now. Try again in a moment." }
        if !(SearchQuery(query)?.isSearchable ?? false) {
            return "Type at least \(SearchQuery.minimumSearchableLength) characters to search messages."
        }
        return "No results."
    }

    /// Runs the message search for the current `query`, after `debounce`.
    /// Call it from a task keyed on the query (`.task(id:)`), so a newer
    /// keystroke cancels this run while it is still waiting.
    public func search() async {
        generation &+= 1
        let run = generation
        guard let parsed = SearchQuery(query), parsed.isSearchable else {
            messageHits = []
            searchFailed = false
            isSearching = false
            return
        }
        isSearching = true
        if debounce > .zero {
            do {
                try await Task.sleep(for: debounce)
            } catch {
                // Cancelled by a newer keystroke (which owns `isSearching`
                // now) or by the view going away.
                if run == generation { isSearching = false }
                return
            }
        }
        guard run == generation else { return }
        // The untrimmed text: a trailing space is how `SearchQuery` knows
        // the last word is finished.
        let outcome: Result<[SearchChatHit], Error>
        do {
            outcome = .success(try await search.queryGrouped(query, limit: Self.candidateLimit))
        } catch {
            outcome = .failure(error)
        }
        guard run == generation else { return }
        isSearching = false
        switch outcome {
        case .success(let hits):
            searchFailed = false
            messageHits = Array(ranked(hits).prefix(Self.resultLimit))
        case .failure:
            searchFailed = true
            messageHits = []
        }
        await resolveConversations(for: messageHits, run: run)
    }

    /// Exact-phrase chats first, then chat-list conversations ahead of the
    /// rest; the service's newest-first order is kept within each.
    private func ranked(_ hits: [SearchChatHit]) -> [SearchChatHit] {
        let listed = Set(allChats.map(\.id))
        func tier(_ hit: SearchChatHit) -> Int {
            (hit.isExact ? 0 : 2) + (listed.contains(hit.roomID) ? 0 : 1)
        }
        return hits.enumerated()
            .sorted { (tier($0.element), $0.offset) < (tier($1.element), $1.offset) }
            .map(\.element)
    }

    /// Looks up the hits' conversations the chat list doesn't hold, and a
    /// subagent chat's parent when that is missing too, so their rows can
    /// be named.
    private func resolveConversations(for hits: [SearchChatHit], run: Int) async {
        guard let lookupConversation else { return }
        let listed = Set(allChats.map(\.id))
        for hit in hits where !listed.contains(hit.roomID) && resolved[hit.roomID] == nil {
            guard let info = await lookupConversation(hit.roomID) else { continue }
            var parent: (id: String, info: ConversationInfo)?
            if let parentID = info.parentID, !listed.contains(parentID), resolved[parentID] == nil,
               let parentInfo = await lookupConversation(parentID) {
                parent = (parentID, parentInfo)
            }
            // What was learned stays true, so it is kept either way; once
            // a newer search owns the list, the remaining lookups are its.
            resolved[hit.roomID] = info
            if let parent { resolved[parent.id] = parent.info }
            guard run == generation else { return }
        }
    }

    /// The current query, ready to hand to the opened chat's
    /// in-conversation search when the user taps a grouped message row.
    /// Untrimmed: the trailing space that finishes the last word must
    /// reach the in-chat search too, or it lists prefix matches the row
    /// did not count.
    public var handoverQuery: String { query }
}

public extension SearchViewModel {
    /// The production `ConversationLookup`: one row from the local journal
    /// mirror, read off the caller's actor.
    static func conversationLookup(store: JournalStore) -> ConversationLookup {
        { convoID in
            await Task.detached {
                guard let record = try? store.conversation(id: convoID) else { return nil }
                return ConversationInfo(title: record.title, parentID: record.parentConvoID)
            }.value
        }
    }
}

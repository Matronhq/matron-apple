import Foundation
import MatronSearch
import MatronChat
import MatronModels

/// Drives the unified search UI on both iOS and Mac. Owns the query string, the
/// FTS message hits, and the chat (title/bot) hits derived from a chat-list
/// snapshot.
@Observable
@MainActor
public final class SearchViewModel {
    public var query: String = ""
    public private(set) var messageHits: [SearchHit] = []
    public private(set) var isSearching = false

    public private(set) var allChats: [ChatSummary]
    private let search: SearchService

    public init(search: SearchService, allChats: [ChatSummary]) {
        self.search = search
        self.allChats = allChats
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

    /// Resolves a room ID to its display title using `allChats`. Falls back to the raw
    /// room ID if the chat isn't in the snapshot (e.g. a search hit from a left room).
    public func chatTitle(for roomID: String) -> String {
        allChats.first(where: { $0.id == roomID })?.title ?? roomID
    }

    /// Row-ready pieces of a search hit's title line: the colored `A:bc`
    /// tag halves plus the title to sit beside them, resolved HERE so the
    /// iOS and Mac call sites compose identically (the row itself lives in
    /// the design system, which by design knows nothing of ChatSummary or
    /// the bridge's title markers).
    public struct HitTitle {
        public let title: String
        public let sessionShort: String?
        public let boxLetter: String?
        public let boxName: String?
        public let roomBoxNames: [String]
        public let roomBoxShorts: [String]
    }

    public func hitTitle(for roomID: String) -> HitTitle {
        guard let chat = allChats.first(where: { $0.id == roomID }) else {
            return HitTitle(title: roomID, sessionShort: nil, boxLetter: nil,
                            boxName: nil, roomBoxNames: [], roomBoxShorts: [])
        }
        // Same marker discipline as the list rows: the room marker drops
        // only when a room tag will actually render in its place.
        let title = chat.roomBoxNames.count >= 2
            ? SessionTag.titleBesideRoomTag(chat.title) : chat.title
        return HitTitle(title: title, sessionShort: chat.sessionShort,
                        boxLetter: chat.boxShort, boxName: chat.boxName,
                        roomBoxNames: chat.roomBoxNames, roomBoxShorts: chat.roomBoxShorts)
    }

    /// Text to display when the query has no chat or message hits.
    public var emptyResultsMessage: String {
        "No results."
    }

    public func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { messageHits = []; return }
        isSearching = true
        defer { isSearching = false }
        messageHits = (try? await search.query(trimmed, limit: 100)) ?? []
    }
}

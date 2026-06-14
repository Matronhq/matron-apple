import Foundation
import MatronSearch
import MatronChat
import MatronModels

/// Drives the unified search UI on both iOS and Mac. Owns the query string, the
/// FTS message hits, and the chat (title/bot) hits derived from a chat-list
/// snapshot. `AggregateBackfillProgress` (from MatronSearch) feeds the empty
/// state so a query with no hits reads "Indexing chats…" while backfill is still
/// in flight rather than a misleading "No results."
@Observable
@MainActor
public final class SearchViewModel {
    public var query: String = ""
    public private(set) var messageHits: [SearchHit] = []
    public private(set) var isSearching = false
    public private(set) var backfillProgress: AggregateBackfillProgress?

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
            $0.title.lowercased().contains(lower) || $0.bot.displayName.lowercased().contains(lower)
        }
    }

    /// Resolves a room ID to its display title using `allChats`. Falls back to the raw
    /// room ID if the chat isn't in the snapshot (e.g. a search hit from a left room).
    public func chatTitle(for roomID: String) -> String {
        allChats.first(where: { $0.id == roomID })?.title ?? roomID
    }

    /// Text to display when the query has no chat or message hits.
    /// During an in-progress backfill, "Indexing chats… (X of Y rooms)" is more accurate
    /// than "No results." since older messages may simply not be indexed yet.
    public var emptyResultsMessage: String {
        if let progress = backfillProgress, progress.inProgress {
            return "Indexing chats… (\(progress.roomsCompleted) of \(progress.roomsTotal) rooms)"
        }
        return "No results."
    }

    public func applyBackfillProgress(_ progress: AggregateBackfillProgress) {
        self.backfillProgress = progress
    }

    /// Subscribes to the coordinator's progress stream and republishes onto this
    /// @MainActor VM so the empty state updates live as rooms finish backfilling.
    public func observeBackfill(_ stream: AsyncStream<AggregateBackfillProgress>) async {
        for await progress in stream {
            applyBackfillProgress(progress)
        }
    }

    public func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { messageHits = []; return }
        isSearching = true
        defer { isSearching = false }
        messageHits = (try? await search.query(trimmed, limit: 100)) ?? []
    }
}

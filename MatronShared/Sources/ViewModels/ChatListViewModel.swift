import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
public final class ChatListViewModel {
    public struct GroupedSummaries: Identifiable, Equatable, Sendable {
        public let group: ChatRecencyGroup
        public let summaries: [ChatSummary]
        public var id: String { group.rawValue }
    }

    public private(set) var groups: [GroupedSummaries] = []
    /// Whether any chat has arrived. Its own property, written only when it
    /// flips, so a view that needs just "is the list populated" does not
    /// re-evaluate on every snapshot the way a read of `groups` does.
    public private(set) var hasChats: Bool = false
    public private(set) var isLoading: Bool = true
    /// Sum of `unreadCount` across every chat in `groups`. Drives the
    /// app-icon badge (iOS `UNUserNotificationCenter.setBadgeCount`)
    /// and the macOS dock badge (`NSApp.dockTile.badgeLabel`). Updated
    /// in lockstep with `groups` from inside the snapshot consumer
    /// loop so the host's `.onChange` listener fires exactly once per
    /// snapshot — no separate stream wiring needed.
    public private(set) var totalUnread: Int = 0
    /// Last error raised by the upstream `chatSummaries()` stream. Phase 2
    /// surfaces this as a banner / `ContentUnavailableView` overlay so a
    /// `SyncReadyError.timeout` doesn't manifest as an "infinite spinner
    /// then silent empty" (QA finding #10). Cleared back to nil on the
    /// next successful snapshot.
    public private(set) var error: String?

    /// The Coordinator's conversation (Coordinator redesign §3b/§3c): left
    /// out of `groups` — the Conversations list — but still counted in
    /// `totalUnread` and published as `hiddenSummary` for the Coordinator
    /// button's unread dot and the panel / sheet title. `nil` hides nothing.
    /// Changing it re-partitions the latest snapshot at once.
    public var hiddenConversationID: String? {
        didSet {
            guard hiddenConversationID != oldValue else { return }
            repartition()
        }
    }
    public private(set) var hiddenSummary: ChatSummary?
    /// The pinned desk chats (journal "Pinned desk chats"): also left out of
    /// `groups` — they have their own entries above the list — and published
    /// as `pinnedSummaries` for those entries' titles and badges. Changing it
    /// re-partitions the latest snapshot at once, like `hiddenConversationID`.
    public var pinnedConversationIDs: Set<String> = [] {
        didSet {
            guard pinnedConversationIDs != oldValue else { return }
            repartition()
        }
    }
    /// The pinned chats in the latest snapshot, by id. A pin whose
    /// conversation is not in the snapshot has no entry.
    public private(set) var pinnedSummaries: [String: ChatSummary] = [:]
    /// Every chat including the hidden and pinned ones — what search reads,
    /// so a hit in the Coordinator or a desk still opens it.
    public var allSummaries: [ChatSummary] {
        groups.flatMap(\.summaries) + (hiddenSummary.map { [$0] } ?? [])
            + pinnedSummaries.values.sorted { $0.id < $1.id }
    }
    /// Sessions that arrived while the app was live without this device
    /// asking for them — an agent, the Coordinator or a routine started
    /// them — and that the user has not opened since. Rows draw a "New"
    /// marker for these: the arrival is shown in the list, never by taking
    /// the selection. In memory only: a relaunch starts
    /// clean, and the unread badge carries on from there.
    public private(set) var newConversationIDs: Set<String> = []

    /// A session arrived quietly (`NewConversation.startedHere == false`).
    /// Hosts skip this for one already on screen.
    public func markNew(_ id: String) {
        if !newConversationIDs.contains(id) { newConversationIDs.insert(id) }
    }

    /// The user opened `id`: it is no longer new. Hosts call this for every
    /// conversation they show, new or not.
    public func markOpened(_ id: String) {
        if newConversationIDs.contains(id) { newConversationIDs.remove(id) }
    }

    /// The newest raw snapshot, kept so `hiddenConversationID` can re-partition.
    private var lastSnapshot: [ChatSummary]?

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    /// Snapshots are applied at most once per interval; see `schedule`.
    private let coalesceInterval: Duration
    private var lastApplied: ContinuousClock.Instant?
    private var pending: Partition?
    private var flushTask: Task<Void, Never>?

    /// - Parameter coalesceInterval: minimum spacing between two applied
    ///   snapshots. The service already coalesces to ~4/s; the list does
    ///   not need that rate (every applied snapshot re-diffs every sidebar
    ///   row), so the default holds it to one a second. Tests pass a
    ///   shorter interval or `.zero`.
    public init(chat: ChatService, coalesceInterval: Duration = .seconds(1)) {
        self.chat = chat
        self.coalesceInterval = coalesceInterval
    }

    /// Subscribes to the long-lived `ChatService.chatSummaries()` stream
    /// (Phase 2.5). The stream yields the broadcaster's latest snapshot
    /// immediately on register, then a fresh snapshot for every diff the
    /// `RoomListSubscription` reports — so an empty first yield (sliding
    /// sync still warming up) just means the next yield will arrive when
    /// rooms land. The pre-Phase-2.5 30×1s retry loop existed only to
    /// mask that one-shot empty-first-snapshot race; with the long-lived
    /// stream it's pure dead code.
    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await snapshot in chat.chatSummaries() {
                    if Task.isCancelled { return }
                    self.lastSnapshot = snapshot
                    let hiding = self.hiddenConversationID
                    let pinned = self.pinnedConversationIDs
                    let result = await Self.derive(from: snapshot, hiding: hiding, pinned: pinned)
                    if Task.isCancelled { return }
                    // The ids changed while this derived: `didSet` already
                    // applied this same snapshot under the new ids.
                    guard hiding == self.hiddenConversationID, pinned == self.pinnedConversationIDs else { continue }
                    self.schedule(result)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    self.error = message
                    self.isLoading = false
                }
            }
        }
    }

    /// Grouping sorts and buckets every chat, so it runs off the main actor:
    /// while agents are live a snapshot lands up to four times a second, and
    /// on the main actor that work competed with a conversation switch.
    private nonisolated static func derive(from snapshot: [ChatSummary], hiding: String?,
                                          pinned: Set<String>) async -> Partition {
        partition(snapshot, hiding: hiding, pinned: pinned)
    }

    /// One snapshot split for the list: the grouped rows, the whole unread
    /// count, the Coordinator's summary and the pinned chats'.
    public struct Partition: Equatable, Sendable {
        public var groups: [GroupedSummaries]
        public var totalUnread: Int
        public var hidden: ChatSummary?
        public var pinned: [String: ChatSummary]
    }

    /// Splits the hidden chat and the pinned ones out of a snapshot. Unread
    /// counts the whole snapshot: the app and dock badges include the
    /// Coordinator and the desks.
    public nonisolated static func partition(_ snapshot: [ChatSummary], hiding hiddenID: String?,
                                             pinned pinnedIDs: Set<String> = []) -> Partition {
        let hidden = hiddenID.flatMap { id in snapshot.first { $0.id == id } }
        var pinned: [String: ChatSummary] = [:]
        var visible: [ChatSummary] = []
        visible.reserveCapacity(snapshot.count)
        for summary in snapshot {
            if summary.id == hiddenID { continue }
            if pinnedIDs.contains(summary.id) {
                pinned[summary.id] = summary
                continue
            }
            visible.append(summary)
        }
        return Partition(groups: group(summaries: visible), totalUnread: snapshot.reduce(0) { $0 + $1.unreadCount },
                         hidden: hidden, pinned: pinned)
    }

    /// Re-applies the latest snapshot under the current hidden and pinned ids.
    private func repartition() {
        guard let lastSnapshot else { return }
        // Supersedes any parked snapshot: `lastSnapshot` is the newest.
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        apply(Self.partition(lastSnapshot, hiding: hiddenConversationID, pinned: pinnedConversationIDs))
    }

    /// Applies a snapshot now if the last one is at least `coalesceInterval`
    /// old; otherwise parks it as `pending` and flushes the latest pending
    /// snapshot when the interval is up. While agents are live the service
    /// yields several snapshots a second (activity timestamps, snippets),
    /// and each applied one makes the sidebar `List` diff every row —
    /// live samples of a 700-row sidebar put that diff inside multi-second
    /// main-thread hangs. Only the newest snapshot matters, so the ones
    /// that arrive inside the interval are dropped, never queued: the list
    /// is at most one interval behind and never plays catch-up.
    private func schedule(_ partition: Partition) {
        let now = ContinuousClock.now
        if let lastApplied, now - lastApplied < coalesceInterval {
            pending = partition
            if flushTask == nil {
                let delay = coalesceInterval - (now - lastApplied)
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    self.flushTask = nil
                    if let pending = self.pending {
                        self.pending = nil
                        self.apply(pending)
                    }
                }
            }
            return
        }
        // A snapshot that lands after the interval but before a scheduled
        // flush resumes must win over the parked one: drop the flush and
        // its (older) snapshot, or it would apply on top of this newer one.
        flushTask?.cancel()
        flushTask = nil
        pending = nil
        apply(partition)
    }

    /// `@Observable` notifies on every write, equal or not, and each
    /// notification re-evaluates every view that read the property — so
    /// only write what actually changed.
    private func apply(_ partition: Partition) {
        lastApplied = .now
        if groups != partition.groups { groups = partition.groups }
        if hiddenSummary != partition.hidden { hiddenSummary = partition.hidden }
        if pinnedSummaries != partition.pinned { pinnedSummaries = partition.pinned }
        let anyChat = !partition.groups.isEmpty || partition.hidden != nil || !partition.pinned.isEmpty
        if hasChats != anyChat { hasChats = anyChat }
        if totalUnread != partition.totalUnread { totalUnread = partition.totalUnread }
        if isLoading { isLoading = false }
        if error != nil { error = nil }
    }

    /// iOS pull-to-refresh / Mac `⌘R` entry point. Drives a one-shot
    /// `client.rooms()` snapshot through the live broadcaster pipe via
    /// `ChatService.forceSnapshot()` — the active `start()` stream
    /// receives the extra yield. The live `RoomListSubscription` and its
    /// per-room handles stay alive; refresh adds a snapshot, never tears
    /// the listener down.
    public func refresh() async {
        do {
            try await chat.forceSnapshot()
        } catch {
            let message = error.localizedDescription
            await MainActor.run {
                self.error = message
            }
        }
    }

    /// Cancels the in-flight observation task. Call from `View.onDisappear`,
    /// or when the session changes / user signs out, so the underlying
    /// AsyncStream's continuation is released. Phase 2.5 flipped
    /// `chatSummaries()` to a long-lived broadcaster stream; cancelling
    /// here unregisters this consumer's continuation without disturbing
    /// the upstream `RoomListSubscription`, so re-`start()` after a
    /// session swap reuses the warm listener.
    public func cancel() {
        observationTask?.cancel()
        observationTask = nil
        flushTask?.cancel()
        flushTask = nil
        pending = nil
    }

    /// The rows a sidebar draws: the newest `limit` chats, still in their
    /// groups, plus how many are left out. The sidebar `List` diffs every
    /// row it holds on each applied snapshot, about once a second while
    /// agents are live; at 1,909 rows that diff alone outlasted the second
    /// on a developer Mac and kept the main thread busy (live sample,
    /// 2026-10-08). The selected chat is always kept, so one opened from
    /// search, a link or a notification still shows as selected: past the
    /// window it is added on its own at the end of its group, rather than
    /// widening the window to reach it.
    public struct SidebarWindow: Equatable, Sendable {
        public var groups: [GroupedSummaries]
        public var hiddenCount: Int
    }

    public nonisolated static func sidebarWindow(_ groups: [GroupedSummaries], limit: Int,
                                                 keeping selectedID: String? = nil) -> SidebarWindow {
        var shown: [GroupedSummaries] = []
        var remaining = max(0, limit)
        var hidden = 0
        for group in groups {
            var rows = Array(group.summaries.prefix(remaining))
            remaining -= rows.count
            if let selectedID, rows.count < group.summaries.count,
               let selected = group.summaries[rows.count...].first(where: { $0.id == selectedID }) {
                rows.append(selected)
            }
            hidden += group.summaries.count - rows.count
            if !rows.isEmpty { shown.append(GroupedSummaries(group: group.group, summaries: rows)) }
        }
        return SidebarWindow(groups: shown, hiddenCount: hidden)
    }

    public nonisolated static func group(summaries: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [GroupedSummaries] {
        let buckets = Dictionary(grouping: summaries) { ChatRecencyGroup.bucket($0.lastActivity, now: now, calendar: calendar) }
        return ChatRecencyGroup.allCases.compactMap { bucket in
            guard let summaries = buckets[bucket]?.sorted(by: Self.byRecencyDescending), !summaries.isEmpty else { return nil }
            return GroupedSummaries(group: bucket, summaries: summaries)
        }
    }

    /// Sort: rooms with a known lastActivity come first, newest first; rooms
    /// with `nil` lastActivity sort by title to give a stable order.
    private nonisolated static func byRecencyDescending(_ a: ChatSummary, _ b: ChatSummary) -> Bool {
        switch (a.lastActivity, b.lastActivity) {
        case let (lhs?, rhs?): return lhs > rhs
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.title < b.title
        }
    }
}

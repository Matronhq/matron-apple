import Foundation
import MatronChat
import MatronModels

/// What a nav entry draws for one chat: its unread and needs-you counts.
public struct ChatCounts: Equatable, Sendable {
    public var unread: Int
    public var needsYou: Int
    public init(unread: Int, needsYou: Int) { self.unread = unread; self.needsYou = needsYou }
    public init(_ summary: ChatSummary) { self.init(unread: summary.unreadCount, needsYou: summary.needsUserCount) }
}

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
    /// `hiddenSummary`'s counts alone, for the nav column's badges: every
    /// message in the Coordinator changes its summary (snippet, time), but
    /// only some move a count, so the window's chrome reads this instead.
    public private(set) var hiddenCounts = ChatCounts(unread: 0, needsYou: 0)
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
    /// The pinned chats' counts, by id — `hiddenCounts` for the desks.
    public private(set) var pinnedCounts: [String: ChatCounts] = [:]
    /// Every chat including the hidden and pinned ones — what search reads,
    /// so a hit in the Coordinator or a desk still opens it.
    public var allSummaries: [ChatSummary] {
        groups.flatMap(\.summaries) + (hiddenSummary.map { [$0] } ?? [])
            + pinnedSummaries.values.sorted { $0.id < $1.id }
    }
    /// Every chat's id and title, in snapshot order. For readers that need
    /// only the titles: it changes far less often than `groups` (which
    /// moves with every snippet and timestamp), and reading it copies two
    /// strings a chat rather than every summary.
    public private(set) var allTitles: [ChatTitle] = []
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

    /// Conversations opened from outside the list (Archived), by id: their
    /// summary as it was when opened, for the chat header to draw while the
    /// conversation is not in the list. A conversation back in the list is
    /// read from the list instead.
    public private(set) var openedOutsideList: [String: ChatSummary] = [:]

    /// The user opened `summary` from somewhere other than the list.
    public func keepSummary(_ summary: ChatSummary) {
        if openedOutsideList[summary.id] != summary { openedOutsideList[summary.id] = summary }
    }

    /// The newest raw snapshot, kept so `hiddenConversationID` can re-partition.

    private var lastSnapshot: [ChatSummary]?

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    /// Snapshots are applied at most once per interval; see `schedule`.
    private let coalesceInterval: Duration
    private var lastApplied: ContinuousClock.Instant?
    /// Replaced through `OffMainRelease`: a dropped partition holds every
    /// chat's summary, and freeing them showed up on main in busy samples.
    @ObservationIgnored private var pending: Partition?
    private var flushTask: Task<Void, Never>?
    /// Where snapshots publish through, if anywhere (the Mac window passes
    /// the shared gate). `nil` publishes as soon as a snapshot is applied.
    private let gate: LiveUpdateGate?
    /// Bumped on every apply, so a gated publish that a newer apply has
    /// overtaken (a repartition published at once) never lands.
    private var applyGeneration = 0

    /// - Parameters:
    ///   - coalesceInterval: minimum spacing between two applied
    ///     snapshots. The service already coalesces to ~4/s; the list does
    ///     not need that rate (every applied snapshot re-diffs every sidebar
    ///     row), so the default holds it to one a second. Tests pass a
    ///     shorter interval or `.zero`.
    ///   - gate: publishes go through it, landing with the window's
    ///     other live updates and held while the user scrolls. A
    ///     repartition (the user's own change) still publishes at once.
    public init(chat: ChatService, coalesceInterval: Duration = .seconds(1), gate: LiveUpdateGate? = nil) {
        self.chat = chat
        self.coalesceInterval = coalesceInterval
        self.gate = gate
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
        /// Every chat's id and title, hidden and pinned ones too.
        public var titles: [ChatTitle] = []
    }

    public struct ChatTitle: Equatable, Sendable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
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
                         hidden: hidden, pinned: pinned,
                         titles: snapshot.map { ChatTitle(id: $0.id, title: $0.title) })
    }

    /// Re-applies the latest snapshot under the current hidden and pinned ids.
    private func repartition() {
        guard let lastSnapshot else { return }
        // Supersedes any parked snapshot: `lastSnapshot` is the newest.
        flushTask?.cancel()
        flushTask = nil
        OffMainRelease.replace(&pending, with: nil)
        apply(Self.partition(lastSnapshot, hiding: hiddenConversationID, pinned: pinnedConversationIDs), now: true)
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
            OffMainRelease.replace(&pending, with: partition)
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
        OffMainRelease.replace(&pending, with: nil)
        apply(partition)
    }

    /// `@Observable` notifies on every write, equal or not, and each
    /// notification re-evaluates every view that read the property — so
    /// only write what actually changed.
    private func apply(_ partition: Partition, now: Bool = false) {
        lastApplied = .now
        applyGeneration += 1
        guard let gate, !now else { return publish(partition) }
        let generation = applyGeneration
        gate.submit(self, "chatList") { [weak self] in
            guard let self, self.applyGeneration == generation else { return }
            self.publish(partition)
        }
    }

    private func publish(_ partition: Partition) {
        let causes = StallCauseRecorder.shared
        if groups != partition.groups {
            OffMainRelease.replace(&groups, with: partition.groups)
            causes.note("ChatList.groups")
        }
        if hiddenSummary != partition.hidden { hiddenSummary = partition.hidden; causes.note("ChatList.hiddenSummary") }
        if pinnedSummaries != partition.pinned { pinnedSummaries = partition.pinned; causes.note("ChatList.pinnedSummaries") }
        let hidden = partition.hidden.map(ChatCounts.init) ?? ChatCounts(unread: 0, needsYou: 0)
        if hiddenCounts != hidden { hiddenCounts = hidden; causes.note("ChatList.hiddenCounts") }
        let pinned = partition.pinned.mapValues(ChatCounts.init)
        if pinnedCounts != pinned { pinnedCounts = pinned; causes.note("ChatList.pinnedCounts") }
        let anyChat = !partition.groups.isEmpty || partition.hidden != nil || !partition.pinned.isEmpty
        if hasChats != anyChat { hasChats = anyChat }
        if allTitles != partition.titles {
            OffMainRelease.replace(&allTitles, with: partition.titles)
            causes.note("ChatList.allTitles")
        }
        if totalUnread != partition.totalUnread { totalUnread = partition.totalUnread; causes.note("ChatList.totalUnread") }
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
        OffMainRelease.replace(&pending, with: nil)
        // Drops a publish still waiting in the gate.
        applyGeneration += 1
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

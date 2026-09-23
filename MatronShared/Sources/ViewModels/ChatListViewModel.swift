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

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    /// Snapshots are applied at most once per interval; see `schedule`.
    private let coalesceInterval: Duration
    private var lastApplied: ContinuousClock.Instant?
    private var pending: (groups: [GroupedSummaries], totalUnread: Int)?
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
                    let (grouped, unread) = await Self.derive(from: snapshot)
                    if Task.isCancelled { return }
                    self.schedule(groups: grouped, totalUnread: unread)
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
    private nonisolated static func derive(from snapshot: [ChatSummary]) async -> ([GroupedSummaries], Int) {
        (group(summaries: snapshot), snapshot.reduce(0) { $0 + $1.unreadCount })
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
    private func schedule(groups grouped: [GroupedSummaries], totalUnread unread: Int) {
        let now = ContinuousClock.now
        if let lastApplied, now - lastApplied < coalesceInterval {
            pending = (grouped, unread)
            if flushTask == nil {
                let delay = coalesceInterval - (now - lastApplied)
                flushTask = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self, !Task.isCancelled else { return }
                    self.flushTask = nil
                    if let pending = self.pending {
                        self.pending = nil
                        self.apply(groups: pending.groups, totalUnread: pending.totalUnread)
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
        apply(groups: grouped, totalUnread: unread)
    }

    /// `@Observable` notifies on every write, equal or not, and each
    /// notification re-evaluates every view that read the property — so
    /// only write what actually changed.
    private func apply(groups grouped: [GroupedSummaries], totalUnread unread: Int) {
        lastApplied = .now
        if groups != grouped { groups = grouped }
        if hasChats != !grouped.isEmpty { hasChats = !grouped.isEmpty }
        if totalUnread != unread { totalUnread = unread }
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

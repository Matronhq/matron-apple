import Foundation
import MatronChat
import MatronModels

@Observable
@MainActor
public final class ChatListViewModel {
    public struct GroupedSummaries: Identifiable {
        public let group: ChatRecencyGroup
        public let summaries: [ChatSummary]
        public var id: String { group.rawValue }
    }

    public private(set) var groups: [GroupedSummaries] = []
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

    public init(chat: ChatService) {
        self.chat = chat
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
                    let grouped = Self.group(summaries: snapshot)
                    let unread = snapshot.reduce(0) { $0 + $1.unreadCount }
                    await MainActor.run {
                        self.groups = grouped
                        self.totalUnread = unread
                        self.isLoading = false
                        self.error = nil
                    }
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
    }

    public static func group(summaries: [ChatSummary], now: Date = Date(), calendar: Calendar = .current) -> [GroupedSummaries] {
        let buckets = Dictionary(grouping: summaries) { ChatRecencyGroup.bucket($0.lastActivity, now: now, calendar: calendar) }
        return ChatRecencyGroup.allCases.compactMap { bucket in
            guard let summaries = buckets[bucket]?.sorted(by: Self.byRecencyDescending), !summaries.isEmpty else { return nil }
            return GroupedSummaries(group: bucket, summaries: summaries)
        }
    }

    /// Sort: rooms with a known lastActivity come first, newest first; rooms
    /// with `nil` lastActivity sort by title to give a stable order.
    private static func byRecencyDescending(_ a: ChatSummary, _ b: ChatSummary) -> Bool {
        switch (a.lastActivity, b.lastActivity) {
        case let (lhs?, rhs?): return lhs > rhs
        case (nil, _?): return false
        case (_?, nil): return true
        case (nil, nil): return a.title < b.title
        }
    }
}

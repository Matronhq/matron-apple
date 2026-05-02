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

    private let chat: ChatService
    private var observationTask: Task<Void, Never>?

    public init(chat: ChatService) {
        self.chat = chat
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in chat.chatSummaries() {
                let grouped = Self.group(summaries: snapshot)
                await MainActor.run {
                    self.groups = grouped
                    self.isLoading = false
                }
            }
        }
    }

    /// Cancels the in-flight observation task. Call from `View.onDisappear`,
    /// or when the session changes / user signs out, so the underlying
    /// AsyncStream's continuation is released. Phase 1's live impl finishes
    /// the stream after one snapshot so this is mostly defensive; once
    /// Phase 2 keeps the stream open across diff updates, calling `cancel()`
    /// is required to avoid Task leaks across re-logins.
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

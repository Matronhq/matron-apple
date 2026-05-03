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

    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await snapshot in chat.chatSummaries() {
                    let grouped = Self.group(summaries: snapshot)
                    await MainActor.run {
                        self.groups = grouped
                        self.isLoading = false
                        self.error = nil
                    }
                }
            } catch {
                // Bubble the upstream error to the View. Don't clear
                // `groups` — the user may have a previous good snapshot
                // they can still interact with; the banner advises that
                // a refresh is needed.
                let message = error.localizedDescription
                await MainActor.run {
                    self.error = message
                    self.isLoading = false
                }
            }
        }
    }

    /// Cancels the in-flight observation task. Call from `View.onDisappear`,
    /// or when the session changes / user signs out, so the underlying
    /// AsyncStream's continuation is released. Phase 2's live impl is
    /// still single-snapshot per call, so this is mostly defensive — but
    /// the cancel keeps re-subscribe churn invisible (QA finding #17).
    /// Phase 3 flips to a long-lived diff stream; at that point this is
    /// required to avoid Task leaks across re-logins.
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

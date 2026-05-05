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
            // `ChatService.chatSummaries()` is single-shot per call (Phase 1/2
            // contract). The first snapshot lands as soon as sliding sync
            // reaches `.running` — but `.running` doesn't guarantee rooms
            // have actually been downloaded yet. Sliding sync delivers rooms
            // incrementally; the first snapshot is often empty even for a
            // user with rooms on the server.
            //
            // Re-poll until we either get a non-empty snapshot or the task
            // is cancelled (`onDisappear` / sign-out). Live-validated bug:
            // user signed in fresh on Mac → list was empty → stayed empty
            // because the VM stopped subscribing after the first (empty)
            // snapshot. Phase 3 SDK-side fix is to flip chatSummaries() to
            // a long-lived diff stream; until then this re-poll keeps the
            // user from being stranded on an empty list.
            //
            // Polling cadence: 1s, capped at 30 attempts (~30s total). After
            // 30s we stop and leave whatever the last snapshot was; the user
            // can pull-to-refresh / ⌘R to retry. Matches the integration
            // test's polling shape (`testChatListShowsRoomCreatedByOtherDevice`).
            let maxAttempts = 30
            for attempt in 0..<maxAttempts {
                if Task.isCancelled { return }
                do {
                    var lastSnapshot: [ChatSummary] = []
                    // Drain the stream fully so a `finish(throwing:)` after
                    // the snapshot yields propagates as an error rather than
                    // being silently swallowed by an early break (the
                    // production stream is single-shot, but tests assert on
                    // the throw + stream error).
                    for try await snapshot in chat.chatSummaries() {
                        lastSnapshot = snapshot
                        let grouped = Self.group(summaries: snapshot)
                        await MainActor.run {
                            self.groups = grouped
                            self.isLoading = false
                            self.error = nil
                        }
                    }
                    if !lastSnapshot.isEmpty { return }  // populated — done
                } catch {
                    let message = error.localizedDescription
                    await MainActor.run {
                        self.error = message
                        self.isLoading = false
                    }
                    return  // upstream errored; no point retrying this session
                }
                // Empty snapshot — wait then retry. Skip the sleep on the
                // last attempt so the loop exits immediately.
                if attempt < maxAttempts - 1 {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
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

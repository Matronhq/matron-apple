import Foundation
import MatronJournal
import MatronModels

public enum JournalChatError: Error, LocalizedError, Equatable {
    case creationNotSupported
    case mediaNotSupported
    case invalidPromptReference(String)

    public var errorDescription: String? {
        switch self {
        case .creationNotSupported:
            return "Creating conversations from the app needs server support (convo_create) — coming soon."
        case .mediaNotSupported:
            return "Attachments need the server's /media endpoint — coming soon."
        case .invalidPromptReference(let id):
            return "Can't answer this prompt — its reference (\"\(id)\") isn't a journal row."
        }
    }
}

/// ChatService over the local journal mirror. The chat list is a pure
/// read of the store; freshness is the sync engine's job.
public final class JournalChatService: ChatService, @unchecked Sendable {
    private let store: JournalStore
    private let engine: JournalSyncEngine
    private let coalesceInterval: Duration

    public init(store: JournalStore, engine: JournalSyncEngine, coalesceInterval: Duration = .milliseconds(250)) {
        self.store = store
        self.engine = engine
        self.coalesceInterval = coalesceInterval
    }

    public func chatSummaries() -> AsyncThrowingStream<[ChatSummary], Error> {
        let store = store
        let interval = coalesceInterval
        return AsyncThrowingStream { continuation in
            // A reconnect replay applies each missed journal frame in its
            // own store transaction, so a catch-up burst yields one
            // conversations snapshot per frame — rendered raw, the chat
            // list visibly pops row by row. Coalesce: the first snapshot
            // goes out immediately (instant paint from the local mirror),
            // then at most one per `interval`, always the newest —
            // `bufferingNewest(1)` drops every intermediate snapshot that
            // lands while the pacer sleeps.
            let (latest, latestCont) = AsyncStream<[ConversationRecord]>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let producer = Task {
                for await records in store.conversationsStream() {
                    latestCont.yield(records)
                }
                latestCont.finish()
            }
            let consumer = Task {
                for await records in latest {
                    continuation.yield(records.map(Self.summary(from:)))
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                producer.cancel()
                consumer.cancel()
            }
        }
    }

    static func summary(from record: ConversationRecord) -> ChatSummary {
        let activityMS = record.lastActivityTS ?? (record.createdAt > 0 ? record.createdAt : nil)
        return ChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
            lastActivity: activityMS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            unreadCount: record.unreadCount,
            snippet: record.snippet
        )
    }

    public func createChat(with botID: String) async throws -> String {
        throw JournalChatError.creationNotSupported
    }

    public func refresh() async throws {
        try await engine.waitUntilReady()
    }

    public func forceSnapshot() async throws {
        await engine.refreshSummaries()
    }

    public func mute(roomID: String) async throws {
        try store.setMuted(true, convoID: roomID)
    }

    public func leave(roomID: String) async throws {
        try store.setHidden(true, convoID: roomID)
    }
}

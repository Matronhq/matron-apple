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
                    // Re-read per emission, not per row: the roster is a
                    // handful of rows and only changes when a snapshot or a
                    // device_meta rename lands.
                    let boxNames = (try? store.agentNames()) ?? [:]
                    continuation.yield(records.map { Self.summary(from: $0, boxNames: boxNames) })
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

    /// `boxNames` is the id → name map of the user's agent boxes. The chip
    /// gate lives here: fewer than two boxes means no chip on any row.
    static func summary(from record: ConversationRecord, boxNames: [Int64: String]) -> ChatSummary {
        let activityMS = record.lastActivityTS ?? (record.createdAt > 0 ? record.createdAt : nil)
        return ChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            bot: BotIdentity(matrixID: "agent:claude", displayName: "Claude", avatarURL: nil),
            lastActivity: activityMS.map { Date(timeIntervalSince1970: Double($0) / 1000) },
            unreadCount: record.unreadCount,
            snippet: record.snippet,
            parentConvoID: record.parentConvoID,
            boxName: Self.boxName(for: record, boxNames: boxNames)
        )
    }

    /// The chip rule for a single conversation: named only when the user has
    /// two or more boxes AND this conversation's box resolves. Pure, so it
    /// is unit-testable without a live sync engine.
    static func boxName(for record: ConversationRecord?, boxNames: [Int64: String]) -> String? {
        guard boxNames.count >= 2, let id = record?.agentDeviceID else { return nil }
        return boxNames[id]
    }

    /// The owning box's display name for one conversation, or `nil` when no
    /// chip should show. Synchronous: both callers are view bodies reading a
    /// handful of rows.
    public func boxName(forConvoID convoID: String) -> String? {
        Self.boxName(for: (try? store.conversation(id: convoID)) ?? nil,
                     boxNames: (try? store.agentNames()) ?? [:])
    }

    static func childSummary(from record: ConversationRecord) -> SubChatSummary {
        SubChatSummary(
            id: record.id,
            title: record.title.isEmpty ? record.id : record.title,
            isRunning: record.sessionState == "running"
        )
    }

    public func children(of parentConvoID: String) -> AsyncStream<[SubChatSummary]> {
        let store = store
        return AsyncStream { continuation in
            let producer = Task {
                for await records in store.childrenStream(of: parentConvoID) {
                    continuation.yield(records.map(Self.childSummary(from:)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
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

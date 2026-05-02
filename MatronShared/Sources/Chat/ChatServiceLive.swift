import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

public final class ChatServiceLive: ChatService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession
    private let sync: MatronSync.SyncService

    public init(provider: ClientProvider, session: UserSession, sync: MatronSync.SyncService) {
        self.provider = provider
        self.session = session
        self.sync = sync
    }

    public func chatSummaries() -> AsyncStream<[ChatSummary]> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await sync.waitUntilReady()
                    let client = try await provider.client(for: session)
                    guard let liveSync = sync as? SyncServiceLive,
                          let sdkSync = await liveSync.sdkService() else {
                        continuation.finish()
                        return
                    }
                    let roomList = try await sdkSync.roomListService().allRooms()
                    let listener = SummaryListener(continuation: continuation, client: client)
                    let result = roomList.entriesWithDynamicAdapters(pageSize: 200, listener: listener)
                    let streamHandle = result.entriesStream()
                    let controller = result.controller()
                    continuation.onTermination = { _ in
                        _ = streamHandle
                        _ = controller
                    }
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private final class SummaryListener: RoomListEntriesListener {
    private let continuation: AsyncStream<[ChatSummary]>.Continuation
    private let client: Client

    init(continuation: AsyncStream<[ChatSummary]>.Continuation, client: Client) {
        self.continuation = continuation
        self.client = client
    }

    func onUpdate(roomEntriesUpdate: [RoomListEntriesUpdate]) {
        let rooms = client.rooms()
        let myID = (try? client.userId()) ?? ""
        let summaries: [ChatSummary] = rooms.map { room in
            let roomID = room.id()
            let title = room.displayName() ?? roomID
            let bot = botIdentity(from: room, excluding: myID, fallbackTitle: title)
            // Timestamps and unread counts require an async hop to room.roomInfo();
            // Phase 1 ships placeholder values to keep the listener synchronous.
            // Phase 2 (timeline view) will subscribe to room info updates and
            // surface real values.
            return ChatSummary(
                id: roomID,
                title: title,
                bot: bot,
                lastActivity: .distantPast,
                unreadCount: 0
            )
        }
        continuation.yield(summaries)
    }

    private func botIdentity(from room: Room, excluding myID: String, fallbackTitle: String) -> BotIdentity {
        let heroes = room.heroes()
        if let hero = heroes.first(where: { $0.userId != myID }) ?? heroes.first {
            return BotIdentity(
                matrixID: hero.userId,
                displayName: hero.displayName ?? hero.userId,
                avatarURL: hero.avatarUrl.flatMap(URL.init(string:))
            )
        }
        return BotIdentity(matrixID: "@unknown:matron", displayName: fallbackTitle, avatarURL: nil)
    }
}

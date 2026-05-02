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
                    // Phase 1 uses a simple polling snapshot via client.rooms()
                    // rather than RoomList.entriesWithDynamicAdapters. The
                    // dynamic-adapters API in v26 crashes inside its internal
                    // VectorDiff::map / BaseStateStore pipeline against tuwunel,
                    // and we don't need real-time diffing for the Phase 1 chat
                    // list. Phase 2 (timeline view) can revisit this with a
                    // real subscription once the SDK path is stable.
                    // Phase 1 yields a single snapshot. Polling continuously
                    // would re-set lastActivity to .now on every tick for any
                    // room whose latestEvent() is still .none (timeline not
                    // hydrated yet), making the relative-time labels visibly
                    // churn. Phase 2 wires real-time room-info subscriptions
                    // and per-room timeline pagination, which gives stable
                    // timestamps and live updates.
                    let rooms = client.rooms()
                    let summaries = await Self.summaries(for: rooms, client: client)
                    continuation.yield(summaries)
                    continuation.finish()
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func summaries(for rooms: [Room], client: Client) async -> [ChatSummary] {
        let myID = (try? client.userId()) ?? ""
        var result: [ChatSummary] = []
        result.reserveCapacity(rooms.count)
        for room in rooms {
            let roomID = room.id()
            let title = room.displayName() ?? roomID
            let bot = botIdentity(from: room, excluding: myID, fallbackTitle: title)
            let lastActivity = await timestamp(of: room.latestEvent()) ?? Date()
            result.append(
                ChatSummary(
                    id: roomID,
                    title: title,
                    bot: bot,
                    lastActivity: lastActivity,
                    unreadCount: 0
                )
            )
        }
        return result
    }

    private static func timestamp(of event: LatestEventValue) -> Date? {
        switch event {
        case .none: return nil
        case .remote(let ts, _, _, _, _),
             .remoteInvite(let ts, _, _),
             .local(let ts, _, _, _, _):
            return Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
        }
    }

    private static func botIdentity(from room: Room, excluding myID: String, fallbackTitle: String) -> BotIdentity {
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

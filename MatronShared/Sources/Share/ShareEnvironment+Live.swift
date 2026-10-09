import Foundation
import MatronAuth
import MatronChat
import MatronJournal
import MatronModels
import MatronStorage

public extension ShareEnvironment {
    /// The real thing, for the share extension: the session and the cached
    /// conversation list come from `container` (the app group the app and
    /// the extension share), everything else from the journal server.
    static func live(container: URL, urlSession: URLSession = .shared) -> ShareEnvironment {
        let sessions = container.appendingPathComponent("sessions")
        return ShareEnvironment(
            session: {
                try? JournalAuthService(sessionStore: FileSessionStore(directory: sessions))
                    .restoreSession()
            },
            cachedTargets: { session in
                ShareTargetsCache.read(userID: session.userID, in: container)
            },
            fetchDirectory: { session in
                let api = JournalAPI(serverURL: session.homeserverURL, urlSession: urlSession,
                                     token: session.accessToken)
                let cached = ShareTargetsCache.read(userID: session.userID, in: container) ?? []
                let snapshot = try await api.snapshot()
                let coordinatorID = cached.first(where: \.isCoordinator)?.id
                return ShareDirectory(
                    targets: targets(from: snapshot, fallbackCoordinatorID: coordinatorID),
                    boxes: boxes(from: snapshot, fallbackCoordinatorID: coordinatorID))
            },
            makeTransport: { session in
                JournalShareTransport(serverURL: session.homeserverURL, token: session.accessToken,
                                      urlSession: urlSession)
            },
            workDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("shared-items", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }

    /// The picker's rows from a server snapshot: top-level conversations
    /// only (a subagent's chat is reached through its parent), titles shown
    /// the way the app's list shows them, and the box named when the user
    /// has more than one. `fallbackCoordinatorID` is for a server that does
    /// not name the Coordinator in its snapshot.
    static func targets(from snapshot: SnapshotResponse, fallbackCoordinatorID: String? = nil) -> [ShareTarget] {
        let coordinatorID = snapshot.coordinatorConvoID ?? fallbackCoordinatorID
        let boxes = snapshot.agents.count > 1
            ? Dictionary(snapshot.agents.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            : [:]
        return snapshot.conversations.filter { $0.parentConvoID == nil }.map { convo in
            let title = SessionTag.splitTitle(convo.title).title
            return ShareTarget(
                id: convo.id,
                title: title.isEmpty ? "Untitled" : title,
                detail: convo.agentDeviceID.flatMap { boxes[$0] },
                isCoordinator: convo.id == coordinatorID,
                lastActivity: convo.lastTS.map { Date(timeIntervalSince1970: Double($0) / 1000) })
        }
    }

    /// The boxes a new conversation can be started on, the one used most
    /// recently first, so the first is a sensible default. The Coordinator
    /// is always the busiest conversation and says nothing about where the
    /// user's own work happens, so it is left out of the reckoning. Boxes
    /// with no conversations come last, by name.
    static func boxes(from snapshot: SnapshotResponse, fallbackCoordinatorID: String? = nil) -> [ShareBox] {
        let coordinatorID = snapshot.coordinatorConvoID ?? fallbackCoordinatorID
        var lastUsed: [Int64: Int64] = [:]
        for convo in snapshot.conversations where convo.parentConvoID == nil && convo.id != coordinatorID {
            guard let box = convo.agentDeviceID, let ts = convo.lastTS else { continue }
            lastUsed[box] = max(lastUsed[box] ?? ts, ts)
        }
        return snapshot.agents
            .sorted { lhs, rhs in
                switch (lastUsed[lhs.id], lastUsed[rhs.id]) {
                case let (l?, r?) where l != r: return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            }
            .map { ShareBox(id: $0.id, name: $0.name) }
    }
}

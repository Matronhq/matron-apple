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
            fetchTargets: { session in
                let api = JournalAPI(serverURL: session.homeserverURL, urlSession: urlSession,
                                     token: session.accessToken)
                let cached = ShareTargetsCache.read(userID: session.userID, in: container) ?? []
                return targets(from: try await api.snapshot(),
                               fallbackCoordinatorID: cached.first(where: \.isCoordinator)?.id)
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
}

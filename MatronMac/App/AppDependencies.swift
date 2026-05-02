import Foundation
import MatronAuth
import MatronChat
import MatronModels
import MatronStorage
import MatronSync

@MainActor
final class AppDependencies {
    let auth: AuthService
    let clientProvider: ClientProvider

    private var syncCache: [String: SyncService] = [:]

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // StoragePaths.appSupport creates the directory on first read.
        let container = StoragePaths.appSupport

        // Phase 1 uses a file-backed session store on Mac for symmetry with
        // iOS — see the iOS AppDependencies for the full rationale. Mac
        // Keychain works without entitlements, so this is the looser of two
        // valid choices; Phase 3 will switch to Keychain when the signing
        // story is settled.
        let sessionStore = FileSessionStore(directory: container.appendingPathComponent("sessions"))
        self.auth = AuthServiceLive(sessionStore: sessionStore, basePath: container)
        self.clientProvider = ClientProvider(basePath: container)
    }

    func syncService(for session: UserSession) -> SyncService {
        if let existing = syncCache[session.userID] { return existing }
        let svc = SyncServiceLive(provider: clientProvider, session: session)
        syncCache[session.userID] = svc
        return svc
    }

    func chatService(for session: UserSession) -> ChatService {
        ChatServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session)
        )
    }
}

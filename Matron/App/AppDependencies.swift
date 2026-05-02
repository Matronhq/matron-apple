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
        // iOS shares its crypto store + search DB with the NSE via the App
        // Group container. Falls back to a tmp dir only when running outside
        // an entitlement (test runner / Previews).
        let container: URL
        #if os(iOS)
        container = (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: StoragePaths.appGroupIdentifier))
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #else
        container = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("matron-fallback")
        #endif
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let keychain = KeychainStore(
            service: "chat.matron.session",
            accessGroup: nil
        )
        self.auth = AuthServiceLive(keychain: keychain, basePath: container)
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

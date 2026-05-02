import Foundation
import SwiftUI
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
    /// Per-session `MediaService` cache. `MediaServiceLive` owns its own
    /// 64 MB `NSCache` for resolved `mxc://` bytes; returning a fresh
    /// instance every call (the prior behaviour) defeated that cache and
    /// re-fetched the same image bytes on every view re-render. Caching
    /// per `userID` keeps the cache shared across rooms in a session.
    private var mediaCache: [String: MediaService] = [:]
    /// Per-room timeline cache keyed by `(userID, roomID)`. Re-using the
    /// same `TimelineServiceLive` across navigations to the same room
    /// preserves the SDK timeline handle and the in-memory snapshot the
    /// diff listener has built up — re-creating would cause a UI flicker
    /// on every push/pop.
    private var timelineCache: [TimelineCacheKey: TimelineService] = [:]

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
        // Split the container into two sibling directories so a fresh-login
        // wipe of the SDK store can never take out the persisted session JSON.
        // - `sdkStore`  : SDK's SQLite + crypto store. Wiped before each login.
        // - `sessions`  : FileSessionStore lives here. Never wiped during login.
        let sdkStore = container.appendingPathComponent("sdk-store")
        let sessionsDir = container.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sdkStore, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Phase 1 uses a file-backed session store rather than Keychain. The
        // iOS Simulator rejects keychain-access-groups entitlements without a
        // signing team, and ad-hoc signing strips them. Phase 3 (verification
        // / recovery key) will add a SessionStore that picks Keychain when
        // entitlements resolve and falls back to file storage otherwise.
        let sessionStore = FileSessionStore(directory: sessionsDir)
        self.auth = AuthServiceLive(sessionStore: sessionStore, basePath: sdkStore)
        self.clientProvider = ClientProvider(basePath: sdkStore)
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

    /// SDK-backed `MediaService` that resolves `mxc://` URLs into bytes via
    /// `Client.getMediaContent`. Cached per `session.userID` so the
    /// 64 MB `NSCache` inside `MediaServiceLive` is shared across rooms
    /// for the lifetime of the session — mirrors the `syncCache` strategy.
    func mediaService(for session: UserSession) -> MediaService {
        if let existing = mediaCache[session.userID] { return existing }
        let svc = MediaServiceLive(provider: clientProvider, session: session)
        mediaCache[session.userID] = svc
        return svc
    }

    /// Per-room `TimelineService` factory. Cached by `(userID, roomID)` so
    /// repeat navigations to the same room re-use the same SDK timeline
    /// handle — that handle owns the in-memory snapshot, so re-creating
    /// it would force the row diff listener to rebuild from scratch and
    /// flicker the UI on every push/pop. Mirrors the `syncCache`
    /// per-session strategy.
    func timelineService(for session: UserSession, roomID: String) -> TimelineService {
        let key = TimelineCacheKey(userID: session.userID, roomID: roomID)
        if let existing = timelineCache[key] { return existing }
        let svc = TimelineServiceLive(
            provider: clientProvider,
            session: session,
            sync: syncService(for: session),
            roomID: roomID
        )
        timelineCache[key] = svc
        return svc
    }
}

/// Composite key for per-room timeline caching. Lives outside
/// `AppDependencies` so the cache type is plain dictionary; the actor
/// isolation comes from `AppDependencies` being `@MainActor`.
private struct TimelineCacheKey: Hashable {
    let userID: String
    let roomID: String
}

// MARK: - SwiftUI Environment

/// Environment key carrying the app-wide `AppDependencies`. Defaulting to
/// `nil` keeps preview/test sites compile-clean without a fake stack;
/// production usage in `MatronApp` always injects a real instance.
struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

/// Environment key carrying the current authenticated `UserSession`. Set
/// by `MatronApp` after sign-in succeeds; read by views that construct
/// per-session services (timeline, media, chat-actions).
struct CurrentSessionKey: EnvironmentKey {
    static let defaultValue: UserSession? = nil
}

extension EnvironmentValues {
    var appDependencies: AppDependencies? {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }
    var currentSession: UserSession? {
        get { self[CurrentSessionKey.self] }
        set { self[CurrentSessionKey.self] = newValue }
    }
}

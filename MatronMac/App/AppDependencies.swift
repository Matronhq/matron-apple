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
    /// Per-session `MediaService` cache. See iOS `AppDependencies` for the
    /// full rationale — `MediaServiceLive` owns a 64 MB `NSCache` for
    /// resolved `mxc://` bytes, and a fresh instance per call defeats it.
    private var mediaCache: [String: MediaService] = [:]
    /// Per-room timeline cache keyed by `(userID, roomID)`. Re-using the
    /// same `TimelineServiceLive` across detail-column transitions
    /// preserves the SDK timeline handle and the in-memory snapshot the
    /// diff listener has built up — re-creating would force the listener
    /// to rebuild from scratch and flicker the UI on every selection
    /// change. Mirrors the iOS `AppDependencies` strategy.
    private var timelineCache: [TimelineCacheKey: TimelineService] = [:]

    init() {
        // Mac uses Application Support — single-process, no App Group.
        // StoragePaths.appSupport creates the directory on first read.
        let container = StoragePaths.appSupport

        // Split the container into two sibling directories so a fresh-login
        // wipe of the SDK store can never take out the persisted session JSON.
        // See the iOS AppDependencies for the full rationale.
        let sdkStore = container.appendingPathComponent("sdk-store")
        let sessionsDir = container.appendingPathComponent("sessions")
        try? FileManager.default.createDirectory(at: sdkStore, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        // Phase 1 uses a file-backed session store on Mac for symmetry with
        // iOS. Phase 3 will switch to Keychain when signing is settled.
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
    /// 64 MB `NSCache` inside `MediaServiceLive` is shared across rooms.
    /// See iOS `AppDependencies` for the full rationale.
    func mediaService(for session: UserSession) -> MediaService {
        if let existing = mediaCache[session.userID] { return existing }
        let svc = MediaServiceLive(provider: clientProvider, session: session)
        mediaCache[session.userID] = svc
        return svc
    }

    /// Per-room `TimelineService` factory. See iOS `AppDependencies` for
    /// the full caching rationale.
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

private struct TimelineCacheKey: Hashable {
    let userID: String
    let roomID: String
}

// MARK: - SwiftUI Environment

/// Environment key carrying the app-wide `AppDependencies` (Mac). The Mac
/// `AppDependencies` is a separate type from the iOS one — they share
/// service-layer code via `MatronShared`, but the per-platform glue
/// (storage container, entitlements) differs.
struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies? = nil
}

/// Environment key carrying the current authenticated `UserSession`.
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

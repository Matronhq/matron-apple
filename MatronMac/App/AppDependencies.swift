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
    ///
    /// Bounded with an LRU cap (`timelineCacheLimit`) so a long session
    /// that flips between many sidebar rooms doesn't accumulate one SDK
    /// timeline handle per room forever. See iOS `AppDependencies` for
    /// the full rationale.
    private var timelineCache: LRUCache<TimelineCacheKey, TimelineService> = .init(limit: AppDependencies.timelineCacheLimit)

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
    /// the full caching rationale (now bounded by `timelineCacheLimit`).
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

    /// Test seam — see iOS `AppDependencies.timelineCacheLimit` for the
    /// rationale and the eviction invariant.
    static let timelineCacheLimit = 16

    /// Test seam — see iOS `AppDependencies.timelineCacheCount`.
    var timelineCacheCount: Int { timelineCache.count }

    /// Test seam — see iOS `AppDependencies.timelineCacheContains(...)`.
    func timelineCacheContains(userID: String, roomID: String) -> Bool {
        timelineCache.contains(TimelineCacheKey(userID: userID, roomID: roomID))
    }
}

private struct TimelineCacheKey: Hashable {
    let userID: String
    let roomID: String
}

/// Tiny, ordered, fixed-capacity cache. See `Matron/App/AppDependencies.swift`
/// (iOS) for the full rationale — duplicated here because the Mac
/// `AppDependencies` is a separate per-target type. If a third caller
/// ever needs this, hoist into a shared utility module.
struct LRUCache<Key: Hashable, Value> {
    private let limit: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []

    init(limit: Int) {
        precondition(limit > 0, "LRU limit must be positive")
        self.limit = limit
    }

    var count: Int { values.count }

    func contains(_ key: Key) -> Bool { values[key] != nil }

    subscript(key: Key) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            if let i = recency.firstIndex(of: key) {
                recency.remove(at: i)
            }
            recency.append(key)
            return value
        }
        set {
            if let newValue {
                if values[key] == nil {
                    recency.append(key)
                } else if let i = recency.firstIndex(of: key) {
                    recency.remove(at: i)
                    recency.append(key)
                }
                values[key] = newValue
                while recency.count > limit {
                    let evict = recency.removeFirst()
                    values.removeValue(forKey: evict)
                }
            } else {
                values.removeValue(forKey: key)
                if let i = recency.firstIndex(of: key) {
                    recency.remove(at: i)
                }
            }
        }
    }
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

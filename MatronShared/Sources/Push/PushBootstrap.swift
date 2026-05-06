import Foundation
import UserNotifications
import MatrixRustSDK
import MatronModels
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform launch hook that wires the user-facing push pipeline
/// once a session is restored:
///
/// 1. **Permission.** `UNUserNotificationCenter.requestAuthorization` —
///    iOS / Mac surface the system prompt the first time. Subsequent
///    calls return the cached decision without re-prompting.
/// 2. **Push rules.** Sets every joined room's notification mode to
///    `.allMessages` so the homeserver emits `notify` actions for
///    every timeline event in the room (spec §8.2).
/// 3. **APNs registration.** Triggers
///    `UIApplication.registerForRemoteNotifications` (iOS) /
///    `NSApplication.registerForRemoteNotifications` (Mac), which the
///    platform's application delegate observes for the device token.
/// 4. **Pusher record.** Once the token arrives via `PushTokenStore`,
///    `register(token:)` calls into `PushService.registerToken(...)`
///    to write the pusher record on the user's homeserver.
///
/// Note (Phase 4 plan deviation): the plan also called for re-enabling
/// `.m.rule.master` on the homeserver via
/// `notificationSettings.setPushRuleEnabled(...)`. That method doesn't
/// exist in v26 of `matrix-rust-components-swift` (only
/// `getRawPushRules() -> String?` and `setCustomPushRule(...)` are
/// exposed). The server-side default has the master rule enabled, and
/// a user explicitly disabling it is a deliberate choice we shouldn't
/// silently override — so this implementation skips that step. If a
/// future SDK version exposes a typed enable/disable surface and we
/// decide we DO want to re-enable on bootstrap, add it next to
/// `setPerRoomNotificationMode` below.
@MainActor
public final class PushBootstrap {
    private let pushService: PushService
    private let pusherBaseURL: URL
    private let notificationSettings: MatronNotificationSettings
    private let joinedRoomIDs: @Sendable () async -> [String]

    public init(
        pushService: PushService,
        pusherBaseURL: URL,
        notificationSettings: MatronNotificationSettings,
        joinedRoomIDs: @escaping @Sendable () async -> [String]
    ) {
        self.pushService = pushService
        self.pusherBaseURL = pusherBaseURL
        self.notificationSettings = notificationSettings
        self.joinedRoomIDs = joinedRoomIDs
    }

    /// Run once per session, post-sync, post-verify. Idempotent on the
    /// homeserver side: re-asking for permission is a no-op, re-setting
    /// `.allMessages` on a room already in `.allMessages` is a no-op,
    /// re-calling `registerForRemoteNotifications` just re-delivers the
    /// existing token to the application delegate.
    ///
    /// Returns `true` on permission grant, `false` if the user declined
    /// — caller can stash the latter to surface in Settings later.
    @discardableResult
    public func bootstrap() async -> Bool {
        let granted = await pushService.requestPermission()
        guard granted else { return false }
        await setPerRoomNotificationMode()
        registerForRemoteNotifications()
        return true
    }

    /// Plumbs the APNs token to the homeserver's pusher record. Called
    /// from the application delegate's `didRegisterForRemoteNotificationsWithDeviceToken`
    /// path (via `PushTokenStore`). Errors are swallowed today — Phase 4
    /// doesn't gate UX on this; Settings UI in a later phase will
    /// surface failures so the user knows pushes aren't wired.
    public func register(token: Data) async {
        do {
            try await pushService.registerToken(token, pusherBaseURL: pusherBaseURL)
        } catch {
            // Intentionally swallow — see method doc.
        }
    }

    /// Walks the current joined-room snapshot and sets each room to
    /// `.allMessages`. The closure-injected `joinedRoomIDs` lets the
    /// caller derive room IDs from whatever it has (chat-list snapshot,
    /// SDK roomList, etc.) without coupling PushBootstrap to the sync
    /// layer. `internal` so `PushBootstrapTests` can call it without
    /// also exercising the system-permission prompt.
    func setPerRoomNotificationMode() async {
        let roomIDs = await joinedRoomIDs()
        for roomID in roomIDs {
            do {
                try await notificationSettings.setRoomNotificationMode(
                    roomId: roomID, mode: .allMessages
                )
            } catch {
                // One bad room shouldn't poison the rest. Continue —
                // the next bootstrap pass (next launch) re-tries.
            }
        }
    }

    private func registerForRemoteNotifications() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }
}

/// Bridge between the platform-specific application delegate (which is
/// where APNs delivers the device token) and the bootstrap flow (which
/// runs in the SwiftUI scene's `.task` and may not be alive when the
/// token arrives). Caches the latest token; bootstrap awaits it via
/// `waitForToken()` and is unblocked the moment the delegate posts.
///
/// `@MainActor` because both producers (the application delegate's
/// `didRegister...` callback) and consumers (SwiftUI `.task` on the
/// MainActor) live on the main thread. No locking needed.
@MainActor
public final class PushTokenStore {
    /// Process-wide singleton — the application delegate's APNs
    /// callback writes here, the bootstrap flow reads. Tests construct
    /// their own instance via the package-internal `init()` so cases
    /// don't bleed state into each other.
    public static let shared = PushTokenStore()

    private var latestToken: Data?
    private var waiters: [CheckedContinuation<Data, Never>] = []

    /// Internal so unit tests can build a fresh store per case.
    /// Production code uses `PushTokenStore.shared`.
    init() {}

    /// Called from the application delegate's
    /// `didRegisterForRemoteNotificationsWithDeviceToken` callback.
    /// Resumes any in-flight `waitForToken()` callers and caches the
    /// token for future calls (e.g. a multi-account switch where
    /// bootstrap fires after the token already arrived).
    public func setToken(_ data: Data) {
        latestToken = data
        let toResume = waiters
        waiters = []
        for continuation in toResume {
            continuation.resume(returning: data)
        }
    }

    /// Suspends until `setToken(_:)` is called. Returns the cached
    /// token immediately if one already exists (the common cold-start
    /// path: APNs delivers before bootstrap awaits). Callers should
    /// await this with a timeout around it if they want to gate UX on
    /// "did push wire up successfully" — Phase 4 doesn't.
    public func waitForToken() async -> Data {
        if let latestToken { return latestToken }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

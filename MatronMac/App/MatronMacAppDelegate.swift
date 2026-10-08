import AppKit
import UserNotifications

/// `NSApplicationDelegate` adaptor for the Mac SwiftUI host. SwiftUI's
/// `App` protocol doesn't expose
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// — same gap as iOS — so APNs token capture lives here.
///
/// `applicationDidFinishLaunching` installs the shared
/// `MacNotificationHandler` as the `UNUserNotificationCenter` delegate
/// so notification taps surface from launch (not lazily on first
/// sign-in).
///
/// Task 12: the token flow is now direct rather than routed through
/// `PushTokenStore` (Matrix-SDK-only machinery this task drops).
/// `MatronMacApp`'s push `.task` sets `registerDeviceToken` to a
/// closure that calls `JournalPushService.registerToken(...)` for the
/// active session; this delegate just forwards whatever token APNs
/// hands it. `registerDeviceToken` is `nil` until a session is signed
/// in (or after sign-out) — an early token delivery is dropped, but
/// `registerForRemoteNotifications()` is called again on every session
/// start, so this doesn't strand a real device. See iOS
/// `MatronAppDelegate` for the parallel rationale.
///
/// `@MainActor`-isolated because `NSApplicationDelegate` callbacks run
/// on the main thread anyway and `MacNotificationHandler` is itself
/// `@MainActor` — without the annotation, the synchronous default-init
/// of `notificationHandler` below trips
/// "call to main actor-isolated initializer in a synchronous
/// nonisolated context" at compile time.
@MainActor
final class MatronMacAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `MatronMacApp`'s push `.task` once a session is signed in.
    var registerDeviceToken: ((Data) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `MacNotificationHandler.shared` is the same instance
        // `MacChatListView` reads `consumePendingRoomID()` off, so
        // a cold-start tap that lands before SwiftUI mounts still
        // gets drained by the chat list's first-mount task.
        UNUserNotificationCenter.current().delegate = MacNotificationHandler.shared
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            registerDeviceToken?(deviceToken)
        }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Phase 4: log only. Likely failure on Mac is "notifications
        // disabled at OS level" (System Settings → Notifications &
        // Focus). Future Settings UI will surface persistent failures.
    }
}

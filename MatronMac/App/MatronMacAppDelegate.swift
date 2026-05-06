import AppKit
import UserNotifications
import MatronPush

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
/// `@MainActor`-isolated because `NSApplicationDelegate` callbacks run
/// on the main thread anyway and `MacNotificationHandler` is itself
/// `@MainActor` — without the annotation, the synchronous default-init
/// of `notificationHandler` below trips
/// "call to main actor-isolated initializer in a synchronous
/// nonisolated context" at compile time.
@MainActor
final class MatronMacAppDelegate: NSObject, NSApplicationDelegate {

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
            PushTokenStore.shared.setToken(deviceToken)
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

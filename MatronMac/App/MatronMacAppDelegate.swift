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

    /// Singleton handler — `UNUserNotificationCenter.current().delegate`
    /// is a single global slot, and the chat-list view layer needs a
    /// stable instance to attach observers to. Same pattern as iOS's
    /// `NotificationDelegate.shared`.
    let notificationHandler = MacNotificationHandler()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = notificationHandler
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

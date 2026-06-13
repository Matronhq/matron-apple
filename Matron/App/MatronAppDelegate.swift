import UIKit
import UserNotifications
import MatronPush

/// `UIApplicationDelegate` adaptor for the SwiftUI host. SwiftUI's
/// `App` protocol doesn't expose
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
/// so iOS push registration needs a delegate. The adaptor on
/// `MatronApp` keeps an instance alive for the process lifetime;
/// SwiftUI hands the system the same instance APNs invokes when the
/// device token arrives or fails.
///
/// The token flow is one-way: `didRegister...` → `PushTokenStore.shared.setToken(_)`,
/// which `PushBootstrap.bootstrap()` (running in the host's `.task`)
/// awaits via `waitForToken()` and forwards to
/// `PushService.registerToken(...)`. Decoupling via the store lets
/// the bootstrap flow start before, during, or after the token
/// arrives — iOS doesn't guarantee an order between SwiftUI scene
/// .task firing and APNs delivery.
///
/// `didFinishLaunchingWithOptions` also installs
/// `NotificationDelegate.shared` as the
/// `UNUserNotificationCenter` delegate so notification taps surface
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)`,
/// which translates to a `tappedRoomID.send(...)` Combine event the
/// host observes to deep-link into the right chat (Task 6).
final class MatronAppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PushTokenStore.shared.setToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Phase 4: log only. iOS Simulator without a paired Mac
        // signing setup hits this every launch — not actionable from
        // app code. Future Settings UI surfaces persistent failures.
    }
}

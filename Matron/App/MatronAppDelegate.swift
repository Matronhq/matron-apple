import UIKit
import UserNotifications

/// `UIApplicationDelegate` adaptor for the SwiftUI host. SwiftUI's
/// `App` protocol doesn't expose
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
/// so iOS push registration needs a delegate. The adaptor on
/// `MatronApp` keeps an instance alive for the process lifetime;
/// SwiftUI hands the system the same instance APNs invokes when the
/// device token arrives or fails.
///
/// Task 11: the token flow is now direct rather than routed through
/// `PushTokenStore`/`PushBootstrap` (Matrix-SDK-only machinery this task
/// drops). `MatronApp`'s push `.task` sets `registerDeviceToken` to a
/// closure that calls `JournalPushService.registerToken(...)` for the
/// active session; this delegate just forwards whatever token APNs hands
/// it. `registerDeviceToken` is `nil` until a session is signed in (or
/// after sign-out), in which case an early token delivery is dropped —
/// the delegate re-fires `didRegister...` any time
/// `registerForRemoteNotifications()` is called again, which the push
/// `.task` does on every session start.
///
/// `didFinishLaunchingWithOptions` also installs
/// `NotificationDelegate.shared` as the
/// `UNUserNotificationCenter` delegate so notification taps surface
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)`,
/// which translates to a `tappedRoomID.send(...)` Combine event the
/// host observes to deep-link into the right chat.
final class MatronAppDelegate: NSObject, UIApplicationDelegate {
    /// Set by `MatronApp`'s push `.task` once a session is signed in.
    /// `@MainActor` isolation matches where both the setter (SwiftUI
    /// `.task`) and this delegate callback (APNs, on main) run.
    @MainActor var registerDeviceToken: ((Data) -> Void)?

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
            registerDeviceToken?(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Log only. iOS Simulator without a paired Mac signing setup hits
        // this every launch — not actionable from app code. Future
        // Settings UI surfaces persistent failures.
    }
}

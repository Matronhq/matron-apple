import AppKit
import Foundation
import UserNotifications
import MatronPush

/// Mac-side `UNUserNotificationCenterDelegate`. Two surfaces:
///
/// - `userNotificationCenter(_:willPresent:)` — controls whether a
///   notification appears while the app is in the foreground. Returns
///   `[.banner, .sound, .list]` so the user sees an in-app banner for
///   off-screen rooms (same shape as iOS's `NotificationDelegate`).
/// - `userNotificationCenter(_:didReceive:)` — fires when the user
///   taps a notification (lock screen, Notification Center, or
///   in-app banner). Activates the app, brings the main window
///   forward, and posts a `.matronOpenRoom` `NotificationCenter`
///   event carrying the `room_id`. `MacChatListView` observes that
///   event and selects the matching `ChatSummary` in the sidebar.
///
/// **Note on silent-payload body construction**: this handler does
/// NOT rewrite the displayed body in `willPresent` — Apple's
/// completion-handler signature only takes presentation options, not
/// modified content, so any mutation made there is dropped on the
/// floor. Mac's equivalent of iOS's NSE rewrite is to handle the
/// silent payload in `NSApplicationDelegate.application(_:didReceiveRemoteNotification:)`,
/// decode the event, and schedule a fresh local notification with
/// the cleartext body. That pipeline is **deferred** for a future
/// commit — the structurally-sound bits (token capture, tap-to-open
/// routing, foreground presentation options) ship now; cleartext
/// silent-push handling needs Sygnal up before it can be validated
/// end-to-end anyway, and the design has wrinkles around session
/// injection that warrant their own design pass.
@MainActor
public final class MacNotificationHandler: NSObject, UNUserNotificationCenterDelegate {

    /// Notification Center key used to carry the room ID through to
    /// `MacChatListView`. Public so the observer side can read it
    /// without re-deriving the string.
    public static let roomIDKey = "roomID"

    public override init() {
        super.init()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        handleTap(userInfo: response.notification.request.content.userInfo)
    }

    /// Public testable surface. The delegate method is hard to drive
    /// from unit tests because `UNNotification` has no public init —
    /// extracting the payload-handling logic to a function that
    /// takes the userInfo dict directly lets tests assert the
    /// `.matronOpenRoom` post + the activate-window side effects
    /// without standing up the full UN pipeline.
    func handleTap(userInfo: [AnyHashable: Any]) {
        guard let roomID = userInfo["room_id"] as? String else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isMainWindow || $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
        NotificationCenter.default.post(
            name: .matronOpenRoom,
            object: nil,
            userInfo: [Self.roomIDKey: roomID]
        )
    }
}

public extension Notification.Name {
    /// Posted by `MacNotificationHandler` when the user taps a
    /// notification. Userinfo carries the `roomID` keyed by
    /// `MacNotificationHandler.roomIDKey`. Distinct from the existing
    /// `MatronCommand` rawValue-derived names because the rawValue
    /// model can't carry a payload — `MatronCommand: String,
    /// CaseIterable` precludes adding `case openRoom(String)`. Worth
    /// keeping the existing menu-bar command bus separate from this
    /// payload-bearing channel rather than migrating both.
    static let matronOpenRoom = Notification.Name("chat.matron.mac.open-room")
}

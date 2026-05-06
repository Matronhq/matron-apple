import Foundation
import Combine
import UserNotifications

/// Routes APNs notification taps to the SwiftUI host so the user lands
/// on the correct chat after tapping a notification banner. Singleton
/// because `UNUserNotificationCenter.current().delegate` is a single
/// global slot — a per-view delegate would either trample or be
/// trampled. The post-verify branch's `.onReceive(tappedRoomID)`
/// observes the subject and appends the matching room onto the
/// chat-list `NavigationStack`'s path.
///
/// Foreground delivery (`willPresent`) returns
/// `[.banner, .sound, .list]` so notifications still appear when the
/// app is open — the user expects an in-app banner for messages from
/// a room other than the one they're looking at, same shape as
/// Element X iOS.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Fires once per notification tap, with the `room_id` extracted
    /// from the notification's `userInfo`. The NSE preserves
    /// `room_id` + `event_id` on the notification when it rewrites
    /// content (Task 4) — this delegate just reads them back.
    let tappedRoomID = PassthroughSubject<String, Never>()

    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let roomID = response.notification.request.content.userInfo["room_id"] as? String {
            tappedRoomID.send(roomID)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

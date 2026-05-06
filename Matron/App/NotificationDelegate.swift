import Foundation
import Combine
import UserNotifications

/// Routes APNs notification taps to the SwiftUI host so the user lands
/// on the correct chat after tapping a notification banner. Singleton
/// because `UNUserNotificationCenter.current().delegate` is a single
/// global slot — a per-view delegate would either trample or be
/// trampled. The post-verify branch's `.onReceive(tappedRoomID)`
/// observes the subject for live taps; the same branch's
/// `.task(id: session.userID)` calls `consumePendingRoomID()` to
/// drain any tap that fired before the SwiftUI tree mounted (cold
/// launch where iOS started the process specifically because the user
/// tapped a notification on the lock screen).
///
/// Foreground delivery (`willPresent`) returns
/// `[.banner, .sound, .list]` so notifications still appear when the
/// app is open — the user expects an in-app banner for messages from
/// a room other than the one they're looking at, same shape as
/// Element X iOS.
///
/// `@MainActor` so `pendingRoomID` mutations from `didReceive` (which
/// UNUserNotificationCenterDelegate guarantees runs on main) don't
/// race the post-verify task's `consumePendingRoomID()` read.
@MainActor
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    /// Fires for live taps that arrive AFTER the SwiftUI host has
    /// mounted its `.onReceive(tappedRoomID)` subscriber. Cold-start
    /// taps (where iOS launched the app because the user tapped a
    /// notification) land in `pendingRoomID` instead — `PassthroughSubject`
    /// doesn't replay missed values, so a value sent before subscription
    /// is silently dropped.
    let tappedRoomID = PassthroughSubject<String, Never>()

    /// Buffered room ID from a cold-start tap. Cleared by
    /// `consumePendingRoomID()` once the host has had a chance to drain
    /// it. Last-write-wins: if the user taps a second notification
    /// before the host drains, the most recent tap is the one that
    /// lands them in a chat (which is the right semantic — a stack of
    /// pending taps would just queue navigations the user didn't ask
    /// for).
    private var pendingRoomID: String?

    private override init() { super.init() }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let roomID = response.notification.request.content.userInfo["room_id"] as? String else {
            return
        }
        // UN guarantees this delegate method runs on the main thread,
        // but the protocol declaration is nonisolated. Hop explicitly
        // so the @MainActor isolation contract on `pendingRoomID` /
        // `tappedRoomID` holds.
        Task { @MainActor in
            self.pendingRoomID = roomID
            self.tappedRoomID.send(roomID)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// Returns and clears any buffered cold-start tap. The host's
    /// post-verify `.task(id: session.userID)` calls this once on
    /// branch mount so a tap that fired before SwiftUI subscribed to
    /// `tappedRoomID` still drives the deep-link.
    func consumePendingRoomID() -> String? {
        let pending = pendingRoomID
        pendingRoomID = nil
        return pending
    }

    /// Drops any buffered tap without consuming it. Called from
    /// `MatronApp.signOut()` so a tap that arrived during the prior
    /// session and was never drained doesn't surface to the next
    /// account's post-verify branch (which would then deep-link a
    /// signed-in user into a room from the previous account — at
    /// best a confusing redirect, at worst a privacy leak in the
    /// brief moment before SDK access checks reject it). Cursor PR
    /// #5 second-pass finding "live taps leave stale pending rooms".
    func clearPendingRoomID() {
        pendingRoomID = nil
    }
}

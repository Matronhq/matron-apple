import AppKit
import Foundation
import UserNotifications

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

    /// Process-wide singleton — `MatronMacAppDelegate` installs
    /// `.shared` as the `UNUserNotificationCenter` delegate and
    /// `MacChatListView` reads its `consumePendingRoomID()` on
    /// first mount to drive the cold-start deep link. Tests still
    /// instantiate fresh handlers via the public init for isolation.
    public static let shared = MacNotificationHandler()

    /// Notification Center key used to carry the room ID through to
    /// `MacChatListView`. Public so the observer side can read it
    /// without re-deriving the string.
    public static let roomIDKey = "roomID"

    /// Buffered room ID from a cold-start tap. `NotificationCenter`
    /// doesn't replay missed posts, so a tap that fires before
    /// `MacChatListView`'s `.onReceive(matronOpenRoom)` subscriber
    /// mounts (the OS launching the app specifically because the
    /// user clicked a notification on the lock screen / Notification
    /// Center) would otherwise be lost. `MacChatListView` calls
    /// `consumePendingRoomID()` from its `.task` to drain on first
    /// appearance — same shape as iOS's `NotificationDelegate`.
    /// Cursor PR #5 third-pass finding "Mac cold-start taps are
    /// dropped".
    private var pendingRoomID: String?

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
        // Buffer first, then post. If the tap is a cold-start (app
        // launched specifically because the user clicked the
        // notification), MacChatListView's `.onReceive` subscriber
        // hasn't mounted yet — the post is lost but the buffer
        // survives for `consumePendingRoomID()` to drain on mount.
        // For live taps where the subscriber IS mounted, the buffer
        // also gets written but is harmless: `consumePendingRoomID`
        // is only called once per session.userID change, and the
        // signOut path clears it via `clearPendingRoomID`.
        pendingRoomID = roomID
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

    /// Returns and clears any buffered cold-start tap. Called from
    /// `MacChatListView.task` on first appearance so a tap that
    /// fired before the SwiftUI tree mounted still drives the deep
    /// link. Idempotent: returns `nil` after the first drain or if
    /// no tap ever landed.
    public func consumePendingRoomID() -> String? {
        let pending = pendingRoomID
        pendingRoomID = nil
        return pending
    }

    /// Drops any buffered tap without consuming it. Called from
    /// `MatronMacApp.signOut(activeSession:)` so a tap that arrived
    /// during the prior session and was never drained doesn't
    /// surface to the next account's first-mount. Mirrors iOS's
    /// `NotificationDelegate.clearPendingRoomID`.
    public func clearPendingRoomID() {
        pendingRoomID = nil
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

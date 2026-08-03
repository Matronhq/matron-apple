import Foundation

/// Resolves the conversation to deep-link into from a tapped
/// notification's `userInfo`. Shared by iOS's `NotificationDelegate` and
/// the Mac's `MacNotificationHandler` so both platforms agree on the
/// payload contract.
///
/// The push relay (`matron-journal` `src/push.js`) carries the
/// conversation id ONLY as `thread-id` inside the `aps` dictionary — it
/// sends no top-level custom key, and without `mutable-content: 1` the
/// NSE that would have rewritten one never runs. Reading `room_id` alone
/// therefore never matched anything and every tap opened the app without
/// navigating. `room_id` stays as the preferred key so an NSE rewrite or
/// a future relay custom key keeps working without an app change.
public enum PushDeepLink {
    public static func roomID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        if let explicit = userInfo["room_id"] as? String, !explicit.isEmpty {
            return explicit
        }
        if let aps = userInfo["aps"] as? [AnyHashable: Any],
           let threadID = aps["thread-id"] as? String, !threadID.isEmpty {
            return threadID
        }
        return nil
    }
}

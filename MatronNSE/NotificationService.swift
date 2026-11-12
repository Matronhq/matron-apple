import UserNotifications

/// The journal server sends alert payloads in plaintext with
/// `mutable-content: 1`, so iOS runs this extension on each one. It only
/// normalises the payload: ensures a visible title, groups the alert by
/// conversation, and copies `convo_id` into userInfo's `room_id` so the
/// host app can deep-link on tap.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        if content.title.isEmpty { content.title = "Matron" }
        if let convoID = content.userInfo["convo_id"] as? String {
            content.threadIdentifier = convoID
            // The host's deep-link path (`PushDeepLink`) reads room_id.
            var userInfo = content.userInfo
            userInfo["room_id"] = convoID
            content.userInfo = userInfo
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Passthrough has nothing async in flight; nothing to salvage.
    }
}

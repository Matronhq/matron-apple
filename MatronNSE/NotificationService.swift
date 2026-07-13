import UserNotifications

/// Journal-era NSE: the server (once APNs lands, v1-completion) sends
/// alert-carrying payloads in plaintext — no per-message crypto bootstrap.
/// This extension only normalises the payload: ensure a visible title and
/// keep convo_id in userInfo so the host app can deep-link on tap.
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
            // Host deep-link path reads room_id (Matrix-era key, kept for reuse).
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

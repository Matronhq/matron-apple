import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        // Phase 1 stub. Phase 4 wires real decryption.
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        // Best-effort fallback if decryption takes too long.
    }
}

import UserNotifications

/// Phase 4 Task 1 stub. Holds onto the OS-supplied `contentHandler` /
/// `bestAttempt` so Task 4 can swap in the real PushDecoder pipeline
/// (`MatronShared/Sources/Push/PushDecoder.swift`) without changing
/// the surrounding NSE lifecycle. Until then, every push is forwarded
/// unmodified — the system shows the encrypted placeholder body.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        self.bestAttempt = request.content.mutableCopy() as? UNMutableNotificationContent
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}

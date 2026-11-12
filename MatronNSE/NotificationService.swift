import MatronPushContent
import UserNotifications

/// Opens a push's sealed content on the device.
///
/// A push arrives with fixed text ("Your agent needs you") and, when this
/// device registered a key, a `box`: what the notification really says,
/// encrypted by the user's journal to that key. Neither the push relay nor
/// Apple can read it. This extension opens the box with the key from the
/// Keychain and writes the title, text and buttons into the notification.
/// Anything that goes wrong leaves the fixed text in place: a notification
/// is never dropped for want of its content.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var fallback: UNMutableNotificationContent?
    private let lock = NSLock()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        if content.title.isEmpty { content.title = "Matron" }
        // A push with no box: the conversation is its thread id, which the
        // app's tap handling reads as it is.
        if let convoID = content.userInfo["convo_id"] as? String {
            content.threadIdentifier = convoID
            var userInfo = content.userInfo
            userInfo["room_id"] = convoID
            content.userInfo = userInfo
        }
        lock.withLock {
            deliver = contentHandler
            fallback = content.mutableCopy() as? UNMutableNotificationContent
        }

        guard let box = content.userInfo["box"] as? String,
              let key = PushKeyStore.live().privateKey(),
              let opened = PushBox.content(of: box, with: key)
        else { return finish(content) }

        opened.apply(to: content)
        lock.withLock { fallback = content.mutableCopy() as? UNMutableNotificationContent }
        guard let labels = opened.item?.actions, !labels.isEmpty else { return finish(content) }
        PushNotificationCategoryRegistrar.ensure(labels: labels) { [weak self] in
            self?.finish(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Only registering a button category can take time; show what there
        // is so far (the opened text, if it got that far) rather than nothing.
        if let fallback = lock.withLock({ self.fallback }) { finish(fallback) }
    }

    /// Delivers once, whichever of the paths above gets here first.
    private func finish(_ content: UNNotificationContent) {
        let handler = lock.withLock { () -> ((UNNotificationContent) -> Void)? in
            defer { deliver = nil }
            return deliver
        }
        handler?(content)
    }
}

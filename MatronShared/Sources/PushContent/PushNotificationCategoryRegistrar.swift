import Foundation
import UserNotifications

/// Registers the category an item's buttons need, before the notification
/// that uses it is shown. Used by the notification extension for each
/// notification with buttons, and by the app at launch for the common ones.
///
/// Registering replaces the whole set, so each call reads the current set
/// and adds to it. Two notifications arriving together (or the app and the
/// extension) would otherwise each write a set without the other's
/// category, so the read, the write and the wait for it to land run one at
/// a time, under a lock file in the app group both processes share. The
/// order of use is kept in the app group's defaults, so the oldest
/// categories can make way for new ones.
public enum PushNotificationCategoryRegistrar {
    static let orderKey = "matron.item.category-order"
    public static let appGroup = "group.chat.matron"

    public static func ensure(labels: [String],
                              center: UNUserNotificationCenter = .current(),
                              defaults: UserDefaults? = UserDefaults(suiteName: appGroup),
                              then finished: @escaping @Sendable () -> Void = {}) {
        // `flock` blocks, so it gets a thread of its own, never the caller's.
        DispatchQueue.global(qos: .userInitiated).async {
            let lock = RegistrationLock.acquire()
            ensureLocked(labels: labels, center: center, defaults: defaults) {
                lock?.release()
                finished()
            }
        }
    }

    private static func ensureLocked(labels: [String], center: UNUserNotificationCenter, defaults: UserDefaults?,
                                     then done: @escaping @Sendable () -> Void) {
        center.getNotificationCategories { existing in
            let order = defaults?.stringArray(forKey: orderKey) ?? []
            guard let next = PushNotificationActions.adding(labels: labels, to: existing, order: order) else {
                return done()
            }
            defaults?.set(next.order, forKey: orderKey)
            center.setNotificationCategories(next.categories)
            // The system takes a new set of categories asynchronously, and
            // a notification shown before it lands has no buttons. Wait
            // until it reads back, for a second at most.
            let identifier = PushNotificationActions.categoryIdentifier(for: labels)
            waitUntilRegistered(identifier, center: center, attemptsLeft: 10, then: done)
        }
    }

    private static func waitUntilRegistered(_ identifier: String, center: UNUserNotificationCenter,
                                            attemptsLeft: Int, then done: @escaping @Sendable () -> Void) {
        center.getNotificationCategories { categories in
            if attemptsLeft <= 0 || categories.contains(where: { $0.identifier == identifier }) {
                return done()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                waitUntilRegistered(identifier, center: center, attemptsLeft: attemptsLeft - 1, then: done)
            }
        }
    }
}

/// An exclusive lock across the app and its extensions, for the length of
/// one registration. Without the app group (an unsigned build) there is no
/// shared file and no lock, which leaves the behaviour as it was.
private final class RegistrationLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire() -> RegistrationLock? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: PushNotificationCategoryRegistrar.appGroup) else { return nil }
        let descriptor = open(container.appendingPathComponent("notification-categories.lock").path,
                              O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX) == 0 else {
            close(descriptor)
            return nil
        }
        return RegistrationLock(descriptor: descriptor)
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

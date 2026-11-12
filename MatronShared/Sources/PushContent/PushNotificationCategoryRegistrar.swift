import Foundation
import UserNotifications

/// Registers the category an item's buttons need, before the notification
/// that uses it is shown. Used by the notification extension for each
/// notification with buttons, and by the app at launch for the common ones.
///
/// Registering replaces the whole set, so each call reads the current set
/// and adds to it. The order of use is kept in the app group's defaults,
/// which the app and the extension share, so the oldest categories can make
/// way for new ones.
public enum PushNotificationCategoryRegistrar {
    static let orderKey = "matron.item.category-order"
    public static let appGroup = "group.chat.matron"

    public static func ensure(labels: [String],
                              center: UNUserNotificationCenter = .current(),
                              defaults: UserDefaults? = UserDefaults(suiteName: appGroup),
                              then done: @escaping @Sendable () -> Void = {}) {
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

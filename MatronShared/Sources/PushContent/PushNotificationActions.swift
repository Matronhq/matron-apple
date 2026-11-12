import CryptoKit
import Foundation
import UserNotifications

/// The buttons on an item's notification.
///
/// iOS shows the actions of the notification's *category*, and a category's
/// button titles are fixed when it is registered. An item's buttons are
/// whatever its agent chose, so each distinct list of labels gets a category
/// of its own, named after a hash of the labels. The notification extension
/// registers the category a notification needs before handing it over; the
/// app registers the common ones at launch.
///
/// A button's identifier is its position in the list. The labels themselves
/// travel in the notification's `userInfo`, so the app answers with the
/// label the user saw, whatever is registered by then.
public enum PushNotificationActions {
    public static let categoryPrefix = "matron.item."
    public static let actionPrefix = "matron.item.action."
    /// Categories for item buttons kept registered at once. The oldest go
    /// first: a notification whose category has gone still shows, without
    /// buttons, and a tap on it opens the item.
    public static let maxDynamicCategories = 32

    /// `userInfo` keys the extension writes for the app to read on a tap.
    public enum Key {
        public static let itemID = "item_id"
        public static let itemActions = "item_actions"
        public static let itemReplyTo = "item_reply_to"
    }

    /// The labels every notice carries, registered up front.
    public static let noticeLabels = ["Seen"]

    public static func categoryIdentifier(for labels: [String]) -> String {
        // Each label with its length in front, so no two lists of labels
        // hash the same input.
        let encoded = labels.map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(encoded.utf8))
        return categoryPrefix + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func actionIdentifier(_ index: Int) -> String { "\(actionPrefix)\(index)" }

    /// The position a tapped button's identifier names, or nil for anything
    /// else (a plain tap, a dismissal, another category's action).
    public static func index(ofActionIdentifier identifier: String) -> Int? {
        guard identifier.hasPrefix(actionPrefix) else { return nil }
        return Int(identifier.dropFirst(actionPrefix.count)).flatMap { $0 >= 0 ? $0 : nil }
    }

    /// Answering an item is a decision, so every button asks for the device
    /// to be unlocked first: nobody answers from someone else's lock screen.
    /// The app is not brought forward; it sends the answer in the background.
    public static func category(for labels: [String]) -> UNNotificationCategory {
        let actions = labels.enumerated().map { index, label in
            UNNotificationAction(identifier: actionIdentifier(index), title: label, options: [.authenticationRequired])
        }
        return UNNotificationCategory(identifier: categoryIdentifier(for: labels), actions: actions,
                                      intentIdentifiers: [], options: [])
    }

    /// `existing` with the category for `labels` added, newest last, and the
    /// oldest item categories dropped past the cap. Categories that are not
    /// item categories are kept as they are. Returns nil when the category
    /// is already there, so the caller can skip registering.
    public static func adding(labels: [String], to existing: Set<UNNotificationCategory>,
                              order: [String]) -> (categories: Set<UNNotificationCategory>, order: [String])? {
        let identifier = categoryIdentifier(for: labels)
        if existing.contains(where: { $0.identifier == identifier }) { return nil }
        var kept = order.filter { id in id != identifier && existing.contains { $0.identifier == id } }
        kept.append(identifier)
        let dropped = Set(kept.dropLast(maxDynamicCategories))
        kept = Array(kept.suffix(maxDynamicCategories))
        var categories = existing.filter { !dropped.contains($0.identifier) }
        categories.insert(category(for: labels))
        return (categories, kept)
    }

    /// What a tap on a button means: which item, which label, and the
    /// comment the button belonged to. Nil when the notification carries no
    /// item or the identifier names no button on it.
    public static func answer(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Answer? {
        guard let index = index(ofActionIdentifier: actionIdentifier),
              let itemID = userInfo[Key.itemID] as? String, !itemID.isEmpty,
              let labels = userInfo[Key.itemActions] as? [String], labels.indices.contains(index)
        else { return nil }
        return Answer(itemID: itemID, label: labels[index], replyTo: userInfo[Key.itemReplyTo] as? String)
    }

    public struct Answer: Equatable, Sendable {
        public let itemID: String
        public let label: String
        public let replyTo: String?
    }
}

public extension PushContent {
    /// Writes this content over a notification's fixed text.
    func apply(to notification: UNMutableNotificationContent) {
        notification.title = title.isEmpty ? "Matron" : title
        notification.subtitle = subtitle ?? ""
        notification.body = body
        notification.threadIdentifier = convoID
        var userInfo = notification.userInfo
        // The app's tap handling reads these (`PushDeepLink`).
        userInfo["room_id"] = convoID
        if let seq { userInfo["seq"] = NSNumber(value: seq) }
        if let item {
            userInfo[PushNotificationActions.Key.itemID] = item.id
            if !item.actions.isEmpty {
                userInfo[PushNotificationActions.Key.itemActions] = item.actions
                if let replyTo = item.replyTo { userInfo[PushNotificationActions.Key.itemReplyTo] = replyTo }
                notification.categoryIdentifier = PushNotificationActions.categoryIdentifier(for: item.actions)
            }
        }
        // The sealed box has done its work; nothing downstream needs it.
        userInfo["box"] = nil
        notification.userInfo = userInfo
    }
}

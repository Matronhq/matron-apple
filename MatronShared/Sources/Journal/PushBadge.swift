import Foundation

/// The unread count a push carries.
///
/// With the Mac's socket closed while nothing is visible, the Dock badge
/// cannot follow the live stream. The journal puts the account's total
/// unread count in `aps.badge` on every alert and on the silent wake it sends
/// when something changes (a message arrives, or a chat is read elsewhere),
/// so the app reads it from the push instead.
public enum PushBadge {
    /// `aps.badge` from a push's `userInfo`, or nil when it carries none (a
    /// push that leaves the badge alone must not clear it). A count below
    /// zero is not a count.
    public static func count(from userInfo: [AnyHashable: Any]) -> Int? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
        let value: Int?
        if let number = aps["badge"] as? NSNumber {
            value = number.intValue
        } else {
            value = aps["badge"] as? Int
        }
        guard let value, value >= 0 else { return nil }
        return value
    }

    /// The Dock tile's label for a count: no label at zero.
    public static func label(for count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }
}

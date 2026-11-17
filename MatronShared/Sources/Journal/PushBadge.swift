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
    /// push that leaves the badge alone must not clear it). Only a whole,
    /// non-negative number that fits an `Int` is a count: a negative, a
    /// fraction (`-0.5` truncates to zero and would clear the badge), a
    /// boolean, NaN or an out-of-range value is ignored.
    public static func count(from userInfo: [AnyHashable: Any]) -> Int? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
        let value: Int?
        if let number = aps["badge"] as? NSNumber {
            value = wholeCount(number)
        } else {
            value = aps["badge"] as? Int
        }
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func wholeCount(_ number: NSNumber) -> Int? {
        // `true` and `false` bridge to NSNumber too.
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        // Whole, and inside the range a double converts to `Int` exactly
        // (2^63 itself is out; `Int(exactly:)` rejects it as well).
        guard double.isFinite, double == double.rounded(.towardZero), double >= 0,
              double < 9_223_372_036_854_775_808 else { return nil }
        return Int(exactly: double)
    }

    /// The Dock tile's label for a count: no label at zero.
    public static func label(for count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }
}

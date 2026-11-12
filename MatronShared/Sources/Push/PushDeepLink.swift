import Foundation

/// Resolves the conversation to deep-link into from a tapped
/// notification's `userInfo`. Shared by iOS's `NotificationDelegate` and
/// the Mac's `MacNotificationHandler` so both platforms agree on the
/// payload contract.
///
/// The push relay (the journal server) sets `mutable-content: 1` on every
/// alert, so on iOS the notification service extension runs and copies the
/// payload's `convo_id` into `room_id` (and the thread identifier). The Mac
/// has no such extension, so the conversation id is also read from
/// `thread-id` inside the `aps` dictionary, where the relay puts it too.
/// `room_id` is preferred when present.
public enum PushDeepLink {
    public static func roomID(fromUserInfo userInfo: [AnyHashable: Any]) -> String? {
        if let explicit = userInfo["room_id"] as? String, !explicit.isEmpty {
            return explicit
        }
        if let aps = userInfo["aps"] as? [AnyHashable: Any],
           let threadID = aps["thread-id"] as? String, !threadID.isEmpty {
            return threadID
        }
        return nil
    }

    /// The journal seq of the message a tapped notification showed — the
    /// relay's top-level `seq` (number, or a numeric string after an NSE
    /// rewrite). Nil for relays that don't send it yet.
    public static func seq(fromUserInfo userInfo: [AnyHashable: Any]) -> Int64? {
        let seq: Int64?
        switch userInfo["seq"] {
        case let number as NSNumber: seq = number.int64Value
        case let string as String: seq = Int64(string)
        default: seq = nil
        }
        return seq.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Notification taps waiting to be reported as seen (read state: the banner
/// showed the message's text). The tap handlers run before, or outside, any
/// signed-in view, so they record here and the view that handles the tap's
/// navigation drains it into the session's `SeenTracker`.
@MainActor
public final class NotificationSeenInbox {
    public static let shared = NotificationSeenInbox()

    public struct Tap: Equatable, Sendable {
        public let convoID: String
        public let seq: Int64
    }

    private var taps: [Tap] = []

    public init() {}

    public func record(convoID: String, seq: Int64) {
        taps.append(Tap(convoID: convoID, seq: seq))
    }

    public func drain() -> [Tap] {
        defer { taps = [] }
        return taps
    }

    /// Sign-out: a tap from the last account must not be reported as the
    /// next one's.
    public func clear() { taps = [] }
}

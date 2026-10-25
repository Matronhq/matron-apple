import Foundation

/// Frees a big value off the main thread. Replacing a published array frees
/// the old one where the setter runs: every element's strings and buffers
/// released one by one, which on a swapped-out heap held main for seconds.
public enum OffMainRelease {
    private static let queue = DispatchQueue(label: "chat.matron.off-main-release", qos: .utility)

    /// Holds the old value until the queue empties it, so the free happens
    /// there whoever drops the box last.
    private final class Retired<T: Sendable>: @unchecked Sendable {
        var value: T?
        init(_ value: T) { self.value = value }
    }

    /// `slot = newValue`, with the old value freed on a background queue.
    public static func replace<T: Sendable>(_ slot: inout T, with newValue: T) {
        let retired = Retired(slot)
        slot = newValue
        queue.async { retired.value = nil }
    }
}

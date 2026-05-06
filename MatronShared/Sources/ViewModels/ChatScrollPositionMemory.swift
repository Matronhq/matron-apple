import Foundation

/// In-memory cache of "last viewed item id" per room, so reopening a chat
/// returns to where the user left off instead of always jumping to the
/// latest message. Survives navigation within the session; resets on app
/// quit. Slack / Discord behave the same way — a persistent restore
/// across launches is overkill and starts dragging in storage concerns.
///
/// `@MainActor` because callers are SwiftUI views, which run on the main
/// actor; isolating here means we don't need a lock for the dictionary.
@MainActor
public enum ChatScrollPositionMemory {
    private static var positions: [String: String] = [:]

    /// Captures the bottom-anchored item id the user was last looking at
    /// in `roomID`. Pass `nil` (or call `forget(roomID:)`) to drop the
    /// entry, which falls back to "open at tail" behaviour next time.
    public static func store(roomID: String, itemID: String?) {
        if let itemID {
            positions[roomID] = itemID
        } else {
            positions.removeValue(forKey: roomID)
        }
    }

    /// Retrieves the previously-stored item id for `roomID`, or `nil` if
    /// the user hasn't viewed this room in this session.
    public static func retrieve(roomID: String) -> String? {
        positions[roomID]
    }

    /// Drops the saved position for a single room. Called on a successful
    /// "jump to bottom" so a subsequent re-open lands at the tail.
    public static func forget(roomID: String) {
        positions.removeValue(forKey: roomID)
    }

    /// Test seam: clear all stored positions.
    public static func _resetForTesting() {
        positions.removeAll()
    }
}

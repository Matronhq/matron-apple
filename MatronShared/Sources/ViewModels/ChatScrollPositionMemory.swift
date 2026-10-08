import Foundation

/// A remembered per-room scroll position. `offsetInRow` is set only by the
/// UIKit timeline (viewport top below the row's top); the SwiftUI timeline's
/// entries are bottom-anchored ids with no offset.
public struct ChatScrollPosition: Equatable, Sendable {
    public let itemID: String
    public let offsetInRow: Double?

    public init(itemID: String, offsetInRow: Double?) {
        self.itemID = itemID
        self.offsetInRow = offsetInRow
    }
}

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
    private static var positions: [String: ChatScrollPosition] = [:]

    /// Captures the bottom-anchored item id the user was last looking at
    /// in `roomID`. Pass `nil` (or call `forget(roomID:)`) to drop the
    /// entry, which falls back to "open at tail" behaviour next time.
    ///
    /// Transient ids (send echoes, the activity indicator) are treated as
    /// `nil`: they name rows that are guaranteed to be gone by the next
    /// open, and restoring one pins the viewport to nothing — the chat
    /// opens blank (2026-07-13 room-switch device traces). A user anchored
    /// to a transient row was at the live tail, and dropping the entry is
    /// exactly the "open at tail" behaviour they expect.
    public static func store(roomID: String, itemID: String?) {
        if let itemID, !isTransient(itemID) {
            positions[roomID] = ChatScrollPosition(itemID: itemID, offsetInRow: nil)
        } else {
            positions.removeValue(forKey: roomID)
        }
    }

    /// The UIKit timeline's entry: the TOP visible row and how far the
    /// viewport's top edge sat below that row's top. Same transient-id rule.
    public static func store(roomID: String, itemID: String, offsetInRow: Double) {
        if isTransient(itemID) {
            positions.removeValue(forKey: roomID)
        } else {
            positions[roomID] = ChatScrollPosition(itemID: itemID, offsetInRow: offsetInRow)
        }
    }

    /// Row ids that never survive to the next open of a room: send
    /// echoes, the activity indicator, and in-flight streaming rows
    /// (`eph:` — replaced by the journal row on finalize; spotted as a
    /// live anchor in the 2026-07-13 23:10 device trace).
    private static func isTransient(_ id: String) -> Bool {
        id == "activity" || id.hasPrefix("echo:") || id.hasPrefix("eph:")
    }

    /// Retrieves the previously-stored item id for `roomID`, or `nil` if
    /// the user hasn't viewed this room in this session.
    ///
    /// The id-only read is the SwiftUI timelines', which restore it
    /// BOTTOM-anchored. A UIKit-timeline entry (it has an `offsetInRow`)
    /// names the TOP visible row, so it reads as `nil` here — a flag flip
    /// opens that room at the tail rather than a screen off, and the SwiftUI
    /// path's `onDisappear` then overwrites the entry with its own.
    public static func retrieve(roomID: String) -> String? {
        guard let position = positions[roomID], position.offsetInRow == nil else { return nil }
        return position.itemID
    }

    /// The full entry — the UIKit timeline reads the offset too.
    public static func retrievePosition(roomID: String) -> ChatScrollPosition? {
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

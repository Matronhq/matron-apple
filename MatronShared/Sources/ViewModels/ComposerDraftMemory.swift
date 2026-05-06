import Foundation

/// In-memory cache of in-flight composer text per room, so navigating
/// back to a room restores whatever the user had typed instead of
/// silently dropping it. Survives navigation within the session; resets
/// on app quit. iMessage / Slack / Discord behave the same way — a
/// persistent restore across launches drags in storage concerns the
/// session-scoped UX doesn't need.
///
/// Mirrors the `ChatScrollPositionMemory` shape (per-room key, public
/// store/retrieve/forget). `@MainActor` because callers are SwiftUI
/// views, which run on the main actor — isolating here means we don't
/// need a lock for the dictionary.
@MainActor
public enum ComposerDraftMemory {
    private static var drafts: [String: String] = [:]

    /// Captures the user's current composer text for `roomID`. Stores
    /// the raw value (no trimming) — collapsing trailing whitespace
    /// would clobber the slash-palette's `"/start "` post-selection
    /// state and make a half-typed "hi " visually rewind on every
    /// navigation. Empty strings clear the entry so a sent-then-empty
    /// composer doesn't ghost text into the next visit.
    public static func store(roomID: String, text: String) {
        if text.isEmpty {
            drafts.removeValue(forKey: roomID)
        } else {
            drafts[roomID] = text
        }
    }

    /// Retrieves the previously-stored draft for `roomID`, or `nil` if
    /// the user hasn't typed in this room this session.
    public static func retrieve(roomID: String) -> String? {
        drafts[roomID]
    }

    /// Drops the saved draft for a single room. Called on a successful
    /// send so the next open lands on an empty composer instead of
    /// re-presenting the just-sent message.
    public static func forget(roomID: String) {
        drafts.removeValue(forKey: roomID)
    }

    /// Test seam: clear all stored drafts.
    public static func _resetForTesting() {
        drafts.removeAll()
    }
}

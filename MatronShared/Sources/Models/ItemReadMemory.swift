import Foundation

/// Persists whether the reader had scrolled to the bottom of a tracker
/// item's comment thread, so reopening the item resumes there instead of
/// always landing at the top — the tracker-item equivalent of
/// `ChatScrollPositionMemory`'s "open where you left off" for chats.
///
/// Backed by `UserDefaults` rather than an in-memory dictionary (unlike
/// `ChatScrollPositionMemory`, which lives in `MatronViewModels`): items
/// are revisited across app launches far more often than a single chat
/// session, and losing the position on every relaunch would defeat the
/// point. `MatronModels` is Foundation-only (no SwiftUI, no `@MainActor`),
/// so this is a plain struct rather than an actor-isolated type — callers
/// are SwiftUI hosts already on the main actor.
public struct ItemReadMemory {
    private let defaults: UserDefaults

    /// - Parameter defaults: injectable for testing; defaults to
    ///   `.standard` for real call sites.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ itemID: String) -> String {
        "items.readToEnd.\(itemID)"
    }

    /// Whether the reader was at the bottom of `itemID`'s comment thread
    /// the last time they viewed it. `false` for an item that's never
    /// been stored — an item nobody has read yet (or that was explicitly
    /// forgotten) opens at the top, not the tail.
    public func wasAtBottom(itemID: String) -> Bool {
        defaults.bool(forKey: key(itemID))
    }

    /// Records whether the reader is currently at the bottom of
    /// `itemID`'s thread.
    public func store(itemID: String, atBottom: Bool) {
        defaults.set(atBottom, forKey: key(itemID))
    }

    /// Drops the stored position for a single item.
    public func forget(itemID: String) {
        defaults.removeObject(forKey: key(itemID))
    }
}

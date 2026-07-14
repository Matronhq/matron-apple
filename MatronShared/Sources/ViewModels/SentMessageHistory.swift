import Foundation

/// Per-room, in-memory history of the user's sent messages, powering
/// terminal-style Up/Down recall in the composer. `ComposerViewModel` owns
/// one instance; storage is keyed by room so a single instance can serve
/// several rooms and stay isolated between them (mirrors
/// `ComposerDraftMemory`'s per-room shape, but as an instance rather than a
/// static enum because recall is *stateful* — it holds a walk cursor and a
/// stashed in-progress draft).
///
/// Survives within the session (as long as the owning view model is cached);
/// resets on app quit. bash / zsh / iMessage behave the same way — Up walks
/// backwards from the most recent, Down walks forward, and stepping past the
/// newest entry restores whatever half-typed draft the user stashed when
/// they began recalling.
///
/// `@MainActor` because callers are the view model / SwiftUI views on the
/// main actor — isolating here means the per-room dictionary needs no lock.
@MainActor
public final class SentMessageHistory {
    /// Max entries retained per room. Older entries fall off the front once
    /// the cap is exceeded.
    private static let cap = 50

    /// Sent messages per room, most-recent last (natural append order).
    private var messagesByRoom: [String: [String]] = [:]

    /// Recall walk state, live only while the user is navigating history.
    /// `recallIndex == nil` means "not navigating". `recallIndex` points at
    /// the currently-shown entry within the room's array; `stashedDraft` is
    /// the in-progress text captured when the walk began, restored on
    /// stepping past the newest entry.
    private var recallRoom: String?
    private var recallIndex: Int?
    private var stashedDraft: String?

    public init() {}

    /// Records a just-sent message for `room`. Consecutive duplicates are
    /// collapsed (sending the same line twice keeps a single entry at the
    /// top — bash `ignoredups` style). Caps the per-room history at `cap`,
    /// dropping the oldest. Recording ends any in-progress recall walk.
    public func record(_ text: String, room: String) {
        endRecall()
        var messages = messagesByRoom[room] ?? []
        if messages.last == text { return }
        messages.append(text)
        if messages.count > Self.cap {
            messages.removeFirst(messages.count - Self.cap)
        }
        messagesByRoom[room] = messages
    }

    /// Whether a recall walk is currently active.
    public var isNavigating: Bool { recallIndex != nil }

    /// Begins or continues walking backwards (Up). The first call stashes
    /// `currentDraft` so a later Down can restore it, and returns the most
    /// recent sent message. Subsequent calls walk toward older entries.
    /// Returns `nil` when there's no history or the oldest entry is already
    /// shown (the caller leaves the field unchanged).
    public func recallOlder(room: String, currentDraft: String) -> String? {
        let messages = messagesByRoom[room] ?? []
        guard !messages.isEmpty else { return nil }
        if recallRoom != room || recallIndex == nil {
            // Fresh walk for this room: stash the draft, start at the newest.
            recallRoom = room
            stashedDraft = currentDraft
            let newest = messages.count - 1
            recallIndex = newest
            return messages[newest]
        }
        guard let idx = recallIndex, idx > 0 else { return nil }
        recallIndex = idx - 1
        return messages[idx - 1]
    }

    /// Walks forward (Down). Returns the next-newer entry, or the stashed
    /// draft — ending the walk — when stepping past the newest entry.
    /// Returns `nil` when not currently navigating this room (the caller
    /// ignores Down).
    public func recallNewer(room: String) -> String? {
        guard recallRoom == room, let idx = recallIndex else { return nil }
        let messages = messagesByRoom[room] ?? []
        if idx < messages.count - 1 {
            recallIndex = idx + 1
            return messages[idx + 1]
        }
        let draft = stashedDraft ?? ""
        endRecall()
        return draft
    }

    /// Ends the current recall walk (e.g. the user edited the field or sent
    /// a message). Idempotent.
    public func endRecall() {
        recallRoom = nil
        recallIndex = nil
        stashedDraft = nil
    }
}

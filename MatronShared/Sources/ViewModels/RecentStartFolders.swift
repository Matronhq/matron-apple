import Foundation

/// Persistent, most-recent-first list of folder paths the user has started
/// sessions in (via `/start` or `/workdir`), powering recent-folder
/// completion in the composer's slash palette.
///
/// Unlike `ComposerDraftMemory` / `SentMessageHistory` — which are
/// session-scoped and in-memory — this store is UserDefaults-backed so a
/// folder typed once is still suggested after an app relaunch. The
/// `UserDefaults` instance is injected (defaulting to `.standard`) purely
/// so tests can point it at a throwaway suite; production always uses the
/// standard domain.
///
/// The stored paths are the raw strings the user typed — they name folders
/// on the *bridge* machine, not the device, so there's nothing to expand
/// or validate locally. Keyed globally rather than per-room: the same
/// bridge machine's folders apply in every conversation.
///
/// `@MainActor` because callers are the composer view model / SwiftUI views
/// on the main actor (mirrors `SentMessageHistory`).
@MainActor
public final class RecentStartFolders {
    /// Max folders retained. Older entries fall off the end once the cap
    /// is exceeded.
    private static let cap = 15

    /// UserDefaults key for the ordered path list. App-global (not
    /// per-room), so a single key holds the whole history.
    private static let defaultsKey = "composer.recentStartFolders"

    private let defaults: UserDefaults

    /// `nonisolated` so it can be evaluated as a default argument for
    /// `ComposerViewModel.init` at a nonisolated call site — the init only
    /// captures the injected (immutable) `defaults` reference; all reads and
    /// writes of the stored list stay main-actor-isolated.
    public nonisolated init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records a folder path the user started a session in. Trims
    /// surrounding whitespace and ignores empty input. A case-insensitive
    /// duplicate is moved to the front (keeping the user's original casing
    /// for the moved entry) rather than added twice. Caps the list at
    /// `cap`, dropping the oldest.
    public func record(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var folders = stored
        folders.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        folders.insert(trimmed, at: 0)
        if folders.count > Self.cap {
            folders.removeLast(folders.count - Self.cap)
        }
        stored = folders
    }

    /// Returns recorded folders whose path has `prefix` as a
    /// case-insensitive prefix, preserving most-recent-first order. An
    /// empty prefix returns the full list (the caller shows all recents).
    public func matches(prefix: String) -> [String] {
        let folders = stored
        guard !prefix.isEmpty else { return folders }
        let needle = prefix.lowercased()
        return folders.filter { $0.lowercased().hasPrefix(needle) }
    }

    /// The persisted ordered list, most-recent-first.
    private var stored: [String] {
        get { defaults.stringArray(forKey: Self.defaultsKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }
}

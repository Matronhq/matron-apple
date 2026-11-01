import AppKit
import MatronModels
import os

/// Clears the window and split-view frames SwiftUI saved under per-build
/// names.
///
/// Until the main `WindowGroup` had an id, SwiftUI named its frame after
/// the root view's full type: about 2.3 KB of text that includes "unknown
/// context at $<address>", and the address changes with every build. Each
/// install left one more window key behind, plus one for the split view,
/// and nothing removed them. Every defaults write then costs a main-thread
/// diff of the whole domain, because `@AppStorage` registers KVO observers
/// on it; launch samples showed that diff as stalls of up to 5 s.
///
/// The window group is now `WindowGroup(id: "main")`, so its frame lives
/// under "NSWindow Frame main-AppWindow-1" and the split view's under a
/// name built from that. No key named after a SwiftUI type is current, so
/// all of them go. It runs before the first window opens, while nothing
/// observes the domain yet. The first launch after the change opens the
/// window at its default size once.
enum StaleAutosaveKeys {
    static let windowPrefix = "NSWindow Frame SwiftUI."
    static let splitViewPrefix = "NSSplitView Subview Frames SwiftUI."

    private static let logger = Logger(subsystem: "chat.matron", category: "stale-autosave-keys")

    /// The keys in `domain` saved under a SwiftUI type name.
    static func staleKeys(in defaults: UserDefaults, domain: String) -> [String] {
        guard let values = defaults.persistentDomain(forName: domain) else { return [] }
        return values.keys.filter { $0.hasPrefix(windowPrefix) || $0.hasPrefix(splitViewPrefix) }
    }

    /// Removes every key saved under a SwiftUI type name from `domain`, in
    /// one write (`MatronDefaults.removeKeys`). Returns how many it removed.
    @discardableResult
    static func prune(_ defaults: UserDefaults, domain: String) -> Int {
        let stale = staleKeys(in: defaults, domain: domain)
        MatronDefaults.removeKeys(stale, fromDomain: domain)
        return stale.count
    }

    /// Prunes the app's own domain and logs what it removed and what is
    /// left, so a Mac's log shows whether the removal held.
    static func pruneAtLaunch() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let removed = prune(.standard, domain: domain)
        guard removed > 0 else { return }
        let left = staleKeys(in: .standard, domain: domain).count
        logger.info("removed \(removed, privacy: .public) stale window and split-view frames, \(left, privacy: .public) left")
    }
}

import AppKit
import os

/// Clears the window and split-view frames SwiftUI saved for earlier builds.
///
/// The main `WindowGroup` has no autosave name of its own, so SwiftUI names
/// its frame after the root view's full type, about 2.3 KB of text that
/// includes "unknown context at $<address>". The address changes with every
/// build, so each install leaves one more key behind (plus a few for the
/// split views), and nothing ever removes them. A Mac that has had a few
/// hundred builds carries half a megabyte of dead key names. Every defaults
/// write then costs a main-thread diff of the whole domain, because
/// `@AppStorage` registers KVO observers on it. Launch samples showed that
/// diff, hashing these keys, as stalls of up to 5 s.
///
/// The keys this launch's windows and split views use are kept, so the
/// window opens where it was left.
enum StaleAutosaveKeys {
    static let windowPrefix = "NSWindow Frame SwiftUI."
    static let splitViewPrefix = "NSSplitView Subview Frames SwiftUI."

    private static let logger = Logger(subsystem: "chat.matron", category: "stale-autosave-keys")

    /// The defaults keys the given windows and their split views save to.
    static func liveKeys(in windows: [NSWindow]) -> Set<String> {
        var keys: Set<String> = []
        for window in windows {
            if !window.frameAutosaveName.isEmpty {
                keys.insert("NSWindow Frame \(window.frameAutosaveName)")
            }
            if let root = window.contentView?.superview ?? window.contentView {
                collectSplitViewKeys(in: root, into: &keys)
            }
        }
        return keys
    }

    private static func collectSplitViewKeys(in view: NSView, into keys: inout Set<String>) {
        if let split = view as? NSSplitView, let name = split.autosaveName, !name.isEmpty {
            keys.insert("NSSplitView Subview Frames \(name)")
        }
        for subview in view.subviews { collectSplitViewKeys(in: subview, into: &keys) }
    }

    /// Removes every SwiftUI-named window or split-view frame not in `live`.
    /// Does nothing unless `live` names a SwiftUI window frame: without one
    /// there is no telling which key is current. Returns how many it removed.
    @discardableResult
    static func prune(_ defaults: UserDefaults, keeping live: Set<String>) -> Int {
        guard live.contains(where: { $0.hasPrefix(windowPrefix) }) else { return 0 }
        let stale = defaults.dictionaryRepresentation().keys.filter { key in
            (key.hasPrefix(windowPrefix) || key.hasPrefix(splitViewPrefix)) && !live.contains(key)
        }
        for key in stale { defaults.removeObject(forKey: key) }
        return stale.count
    }

    /// Prunes once, `delay` seconds after launch, well clear of the launch
    /// work: the removal itself pays for one more diff of the big domain.
    @MainActor
    static func pruneAfterLaunch(delay: TimeInterval = 60) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let removed = prune(.standard, keeping: liveKeys(in: NSApp.windows))
            if removed > 0 {
                logger.info("removed \(removed, privacy: .public) stale window and split-view frames")
            }
        }
    }
}

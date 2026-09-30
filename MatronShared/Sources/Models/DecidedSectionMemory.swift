import Foundation

/// Persists whether the Decisions view's "Decided" section is expanded, so
/// leaving it open (or collapsed) survives a relaunch — the same
/// UserDefaults-backed pattern `ItemReadMemory` uses for a tracker item's
/// scroll position, for the same reason: this is revisited across app
/// launches, not just within one session.
public struct DecidedSectionMemory {
    private let defaults: UserDefaults
    private static let key = "decisions.decidedSectionExpanded"

    /// - Parameter defaults: injectable for testing; defaults to
    ///   `.standard` for real call sites.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `false` (collapsed) until the user has expanded it at least once —
    /// mirrors the Missions tab's own closed section, which also starts
    /// collapsed.
    public func load() -> Bool {
        defaults.bool(forKey: Self.key)
    }

    public func store(_ expanded: Bool) {
        defaults.set(expanded, forKey: Self.key)
    }
}

import CoreGraphics

/// What a platform timeline view must do for `TimelineSession`.
///
/// Ownership: the platform controller owns the session and is its surface.
/// The session holds the surface weakly; callbacks after the surface is gone
/// are dropped (`hasPendingWork` reads false, `hasVisibleRows()` true).
@MainActor protocol TimelineSurface: AnyObject {
    /// Replace the displayed rows (ids in order) with no animation; rows in
    /// `reconfigure` keep their view and re-render; rows in `reload` get a
    /// fresh view (their kind changed). Called inside `performLayoutUpdate`.
    func applyRows(_ ids: [String], reconfigure: [String], reload: [String])
    /// Write `offsetY` to the scroll view (content space, top-down) and lay out.
    /// Called once per `performLayoutUpdate`, after the model changed; the
    /// surface re-lays out every time and writes the offset only when its
    /// scroll view is more than 0.25pt away from it.
    func setContentOffset(_ offsetY: CGFloat)
    /// Stop any in-flight deceleration/momentum. Runs inside the session's
    /// layout guard (scroll callbacks are ignored) but outside any access to
    /// its `scrollModel`, so it may scroll and lay out synchronously.
    func killMomentum()
    /// True when at least one row view is on screen (the blank-chat tripwire).
    /// A surface not in a window returns `true`, so the tripwire never fires.
    func hasVisibleRows() -> Bool
    /// Briefly highlight the row (jump landing).
    func flashRow(_ id: String)
    /// A precompute is in flight or a sync is already scheduled.
    var hasPendingWork: Bool { get }
    /// Schedule one coalesced `sync` on the next frame.
    func requestSync()
    /// The follow state changed (drives the jump button).
    func followingChanged(_ following: Bool)
    /// The scroll view's real offset right now (content space, top-down),
    /// for diagnostics only — the INVARIANT breadcrumb logs it beside the
    /// model's. `nil` (the default) when the surface doesn't report one.
    var currentOffsetY: CGFloat? { get }
}

extension TimelineSurface {
    var currentOffsetY: CGFloat? { nil }
}

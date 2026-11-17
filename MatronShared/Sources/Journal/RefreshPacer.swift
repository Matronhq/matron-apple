import Foundation
import os

/// Whether the app is in front, for work that only pays off while someone
/// is looking: re-reading lists from the journal, fetching what a tracker
/// event changed. The iOS app sets it from its scene phase and from the
/// application state at launch; a host that never sets it (the Mac, tests)
/// counts as always active.
///
/// `@unchecked`: the state sits behind the lock.
public final class AppActivity: @unchecked Sendable {
    public static let shared = AppActivity()

    private struct State {
        var active = true
        var watchers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(active: Bool = true) {
        state.withLock { $0.active = active }
    }

    public var isActive: Bool { state.withLock { $0.active } }

    /// Records the change; going from inactive to active wakes every
    /// `becameActive()` stream.
    public func setActive(_ active: Bool) {
        let wake = state.withLock { s -> [AsyncStream<Void>.Continuation] in
            defer { s.active = active }
            return !s.active && active ? Array(s.watchers.values) : []
        }
        for watcher in wake { watcher.yield() }
    }

    /// Yields each time the app comes back to the front. Holds at most one
    /// pending wake.
    public func becameActive() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            state.withLock { $0.watchers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { _ = $0.watchers.removeValue(forKey: id) }
            }
        }
    }
}

/// When a store re-reads a list from the journal that it otherwise keeps
/// current from live events: on each reconnect and each return to the
/// front, but at most once per `interval`, and never while the app is in
/// the background (a silent push's wake catches up the journal, nothing
/// more). A phone reconnects every time it is opened or woken, so without
/// this every store sends its request a hundred times a day for answers
/// that rarely change.
///
/// `@unchecked`: the state sits behind the lock.
public final class RefreshPacer: @unchecked Sendable {
    /// How long a list read from the journal is taken to be current. On the
    /// iPhone, which reconnects each time it is opened or woken, 10 minutes:
    /// a change made elsewhere while it was offline shows within that. The
    /// Mac reconnects rarely and reads on every reconnect, as before.
    #if os(iOS)
    public static let defaultInterval: Duration = .seconds(10 * 60)
    #else
    public static let defaultInterval: Duration = .zero
    #endif

    private let interval: Duration
    private let activity: AppActivity
    private let now: @Sendable () -> ContinuousClock.Instant
    private let last = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)

    public init(interval: Duration = RefreshPacer.defaultInterval, activity: AppActivity = .shared,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.interval = interval
        self.activity = activity
        self.now = now
    }

    /// Whether a refresh asked for now should go out, and if so records it.
    /// `changed` says the store knows its list changed (a tracker event it
    /// did not fetch): that skips the interval, but not the background rule.
    public func take(changed: Bool = false) -> Bool {
        guard activity.isActive else { return false }
        let at = now()
        return last.withLock { last in
            if !changed, let previous = last, at - previous < interval { return false }
            last = at
            return true
        }
    }

    /// How long until `take()` would let a refresh out, or nil while the
    /// app is in the background (the return to the front asks then).
    public func untilNext() -> Duration? {
        guard activity.isActive else { return nil }
        let at = now()
        return last.withLock { last in
            guard let previous = last else { return .zero }
            return max(.zero, interval - (at - previous))
        }
    }

    /// Whether the app is in front now (`AppActivity`).
    public var isAppActive: Bool { activity.isActive }

    /// Forgets the last refresh, so the next `take` goes out: for a refresh
    /// that failed and so did not make the list current.
    public func reset() {
        last.withLock { $0 = nil }
    }

    /// Yields when the app comes back to the front, for stores to `take`.
    public func foregroundSignals() -> AsyncStream<Void> {
        activity.becameActive()
    }
}

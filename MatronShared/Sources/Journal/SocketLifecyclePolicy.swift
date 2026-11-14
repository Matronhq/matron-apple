import Foundation

/// Decides when the Mac app should hold its journal socket open.
///
/// A pure value type: no AppKit, no clock, no sockets. The host feeds it
/// what it observed (are any windows visible, is the machine asleep) with
/// timestamps and applies the decision it gets back.
///
/// The socket is wanted while a window can be seen, and for `grace` seconds
/// after the last one stops being visible (hidden, minimised, occluded). It
/// is not wanted while the machine sleeps. Once it is closed it comes back,
/// resuming from the stored cursor, when a window is visible again or the
/// machine wakes with one visible.
///
/// The process must not be napped while the socket is wanted: App Nap
/// throttles the timers behind the engine's ping watchdog and backoff
/// sleeper, so a dropped socket would go unnoticed. `holdsActivity` says when
/// the host must hold an activity assertion. It lets go once the socket is
/// closed, which is what lets the Mac idle.
public struct SocketLifecyclePolicy: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// Leave the socket as it is.
        case keep
        /// Close the socket (stop sync).
        case close
        /// Open it again and resume from the stored cursor.
        case reconnectFromCursor
    }

    public let grace: TimeInterval
    public private(set) var windowsVisible: Bool
    public private(set) var asleep: Bool
    /// When the last visible window went away; nil while one is visible.
    public private(set) var hiddenSince: TimeInterval?
    /// True once a `.close` decision was handed out and no reconnect since.
    public private(set) var socketClosed: Bool

    /// Starts with the socket open, as the app does at launch.
    public init(grace: TimeInterval = 60, windowsVisible: Bool = true, asleep: Bool = false, now: TimeInterval = 0) {
        self.grace = grace
        self.windowsVisible = windowsVisible
        self.asleep = asleep
        self.hiddenSince = windowsVisible ? nil : now
        self.socketClosed = false
    }

    public mutating func setWindowsVisible(_ visible: Bool, at now: TimeInterval) {
        guard visible != windowsVisible else { return }
        windowsVisible = visible
        hiddenSince = visible ? nil : now
    }

    public mutating func setAsleep(_ value: Bool, at now: TimeInterval) {
        guard value != asleep else { return }
        asleep = value
        // Waking with nothing visible (a dark wake) must not hold a socket
        // for a fresh grace period: count the grace as already spent.
        if !value, !windowsVisible { hiddenSince = now - grace }
    }

    /// Whether the socket should be open at `now`.
    public func wantsSocket(at now: TimeInterval) -> Bool {
        if asleep { return false }
        if windowsVisible { return true }
        guard let hiddenSince else { return true }
        return now - hiddenSince < grace
    }

    /// Whether the process must stay out of App Nap: from launch until the
    /// close is applied, and again from the reconnect.
    public var holdsActivity: Bool { !socketClosed }

    /// Compares what is wanted with what was last decided. Each change is
    /// handed out once; call again after any `set...` and at `nextDeadline`.
    public mutating func decide(at now: TimeInterval) -> Decision {
        switch (wantsSocket(at: now), socketClosed) {
        case (true, false), (false, true):
            return .keep
        case (false, false):
            socketClosed = true
            return .close
        case (true, true):
            socketClosed = false
            return .reconnectFromCursor
        }
    }

    /// When `decide` will next return `.close` without any other input.
    public var nextDeadline: TimeInterval? {
        guard !socketClosed, !asleep, !windowsVisible, let hiddenSince else { return nil }
        return hiddenSince + grace
    }
}

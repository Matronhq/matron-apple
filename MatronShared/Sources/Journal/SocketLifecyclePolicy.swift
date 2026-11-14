import Foundation

/// Decides when the Mac app should hold its journal socket open.
///
/// A pure value type: no AppKit, no clock, no sockets. The host feeds it
/// what it observed (windows, activation, sleep, work the user started) with
/// timestamps and applies the decision it gets back.
///
/// The socket is wanted:
/// - while the app is in the foreground: a window can be seen. While the
///   displays sleep nothing can be seen, so that is not the foreground;
/// - for `activationWindow` seconds after the app starts to activate, so
///   coming back reconnects before a window is drawn. Activation alone does
///   not outlast that: closing the last window while Matron stays frontmost
///   still lets the socket close;
/// - for `grace` seconds after the foreground ends, as a fallback for the
///   real events below (a quick glance away does not close it);
/// - while the user has work in flight that needs it: a voice note recording
///   or sending, or messages waiting in the outbox;
/// - always, when the user chose "stay connected in the background".
///
/// It is not wanted while the machine sleeps, whatever else holds. Once it is
/// closed it comes back, resuming from the stored cursor, as soon as any of
/// the above holds again.
///
/// The process must not be napped while the socket is open without a window
/// on screen: App Nap throttles the timers behind the engine's ping watchdog,
/// backoff sleeper and the close deadline itself. `holdsActivity` says when
/// the host must hold an activity assertion. A window that can be seen keeps
/// the app out of App Nap on its own, so no assertion is held then, and none
/// once the socket is closed, which is what lets the Mac idle.
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
    /// How long activation alone may hold the socket while no window is
    /// visible.
    public let activationWindow: TimeInterval
    public private(set) var windowsVisible: Bool
    /// The app is active, or activation has begun.
    public private(set) var appActive: Bool
    /// When `appActive` last turned true.
    public private(set) var activeSince: TimeInterval
    /// The machine is asleep.
    public private(set) var asleep: Bool
    /// The displays are asleep while the machine stays awake.
    public private(set) var displaysAsleep: Bool
    /// A voice note is recording, starting or sending.
    public private(set) var voiceNoteActive: Bool
    /// Messages are queued waiting for a socket.
    public private(set) var outboxPending: Bool
    /// The user's "stay connected in the background" choice.
    public private(set) var stayConnected: Bool
    /// When the foreground last ended; nil while it holds.
    public private(set) var hiddenSince: TimeInterval?
    /// True once a `.close` decision was handed out and no reconnect since.
    public private(set) var socketClosed: Bool

    /// Starts with the socket open, as the app does at launch.
    public init(grace: TimeInterval = 60, activationWindow: TimeInterval = 5, windowsVisible: Bool = true,
                appActive: Bool = false, asleep: Bool = false, now: TimeInterval = 0) {
        self.grace = grace
        self.activationWindow = activationWindow
        self.windowsVisible = windowsVisible
        self.appActive = appActive
        self.activeSince = now
        self.asleep = asleep
        self.displaysAsleep = false
        self.voiceNoteActive = false
        self.outboxPending = false
        self.stayConnected = false
        self.socketClosed = false
        self.hiddenSince = nil
        self.hiddenSince = foreground ? nil : now
    }

    /// A window is in front of the user. Only this keeps the socket without
    /// a time limit.
    public var foreground: Bool { windowsVisible && !displaysAsleep }

    /// Activation began less than `activationWindow` ago, and something can
    /// be seen at all.
    public func activating(at now: TimeInterval) -> Bool {
        appActive && !displaysAsleep && now - activeSince < activationWindow
    }

    /// The user has asked for the socket by what they are doing or chose.
    public var held: Bool { voiceNoteActive || outboxPending || stayConnected }

    // MARK: Inputs

    public mutating func setWindowsVisible(_ visible: Bool, at now: TimeInterval) {
        change(at: now) { $0.windowsVisible = visible }
    }

    public mutating func setAppActive(_ active: Bool, at now: TimeInterval) {
        guard active != appActive else { return }
        appActive = active
        if active { activeSince = now }
    }

    public mutating func setDisplaysAsleep(_ value: Bool, at now: TimeInterval) {
        change(at: now) { $0.displaysAsleep = value }
    }

    public mutating func setVoiceNoteActive(_ value: Bool, at now: TimeInterval) {
        change(at: now) { $0.voiceNoteActive = value }
    }

    public mutating func setOutboxPending(_ value: Bool, at now: TimeInterval) {
        change(at: now) { $0.outboxPending = value }
    }

    public mutating func setStayConnected(_ value: Bool, at now: TimeInterval) {
        change(at: now) { $0.stayConnected = value }
    }

    public mutating func setAsleep(_ value: Bool, at now: TimeInterval) {
        guard value != asleep else { return }
        asleep = value
        // Waking with nothing in front (a dark wake) must not hold a socket
        // for a fresh grace period: count the grace as already spent.
        if !value, !foreground { hiddenSince = now - grace }
    }

    /// Applies a change and restarts the grace when the foreground ends.
    private mutating func change(at now: TimeInterval, _ apply: (inout SocketLifecyclePolicy) -> Void) {
        let before = foreground
        apply(&self)
        let after = foreground
        guard before != after else { return }
        hiddenSince = after ? nil : now
    }

    // MARK: Outputs

    /// Whether the socket should be open at `now`.
    public func wantsSocket(at now: TimeInterval) -> Bool {
        if asleep { return false }
        if held || foreground || activating(at: now) { return true }
        guard let hiddenSince else { return true }
        return now - hiddenSince < grace
    }

    /// A window is on screen: the system keeps the app out of App Nap.
    public var windowKeepsAwake: Bool { windowsVisible && !displaysAsleep }

    /// Whether the host must hold an activity assertion: while the socket is
    /// open (or about to be) and no window on screen keeps the app awake.
    public var holdsActivity: Bool { !socketClosed && !windowKeepsAwake }

    /// A `decide` would close the socket now. The host checks the outbox
    /// first, so a close never rests on a stale `outboxPending`.
    public func wouldClose(at now: TimeInterval) -> Bool {
        !socketClosed && !wantsSocket(at: now)
    }

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
        guard !socketClosed, !asleep, !held, !foreground, let hiddenSince else { return nil }
        var deadline = hiddenSince + grace
        if appActive, !displaysAsleep { deadline = max(deadline, activeSince + activationWindow) }
        return deadline
    }
}

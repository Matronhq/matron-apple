import Foundation

/// What the live connection learned about this device's credentials.
public enum CredentialSignal: Sendable, Equatable {
    /// The journal accepted the token (`hello_ok`).
    case accepted
    /// The journal refused the token at the handshake (`error` code
    /// `auth`): the device was signed out, from another device or by the
    /// server. Definitive.
    case rejected
}

/// Decides when this device's credentials have been revoked, so the app can
/// run its normal sign-out and return to the sign-in screen instead of
/// sitting offline over a mirror it can no longer sync.
///
/// Two inputs:
/// - the WebSocket handshake (`handle(_:)`): a `.rejected` hello is the
///   journal saying in so many words that this token is no longer valid, so
///   it fires at once;
/// - REST responses to token-bearing requests (`noteResponse(status:)`): a
///   single 401 is not enough (a proxy hiccup or a request racing a server
///   restart can produce one), so it fires only once 401s *keep* coming —
///   `rejectionThreshold` in a row, spread over at least `minimumSpan`,
///   with nothing in between that shows the token still works. Any answer
///   the server could only give an authenticated caller (2xx, 403, 404 …)
///   or an accepted hello resets the count. 403 is never a revoke: it is
///   one resource refusing an otherwise valid device. Network failures,
///   429 and 5xx say nothing about the token and leave the count alone.
///
/// Fires `onRevoked` at most once per monitor; `cancel()` disarms it (the
/// sign-out teardown calls it so its own calls with the dead token cannot
/// re-trigger anything). Thread-safe: inputs arrive from the API actor and
/// the sync engine concurrently.
public final class CredentialRevocationMonitor: @unchecked Sendable {
    private let rejectionThreshold: Int
    private let minimumSpan: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let onRevoked: @Sendable () -> Void

    private let lock = NSLock()
    private var consecutiveRejections = 0
    private var firstRejectionAt: ContinuousClock.Instant?
    private var armed = true
    private var fired = false

    public init(
        rejectionThreshold: Int = 3,
        minimumSpan: Duration = .seconds(10),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        onRevoked: @escaping @Sendable () -> Void
    ) {
        self.rejectionThreshold = max(1, rejectionThreshold)
        self.minimumSpan = minimumSpan
        self.now = now
        self.onRevoked = onRevoked
    }

    /// Whether `onRevoked` has run.
    public var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    /// The sync engine's handshake outcome.
    public func handle(_ signal: CredentialSignal) {
        switch signal {
        case .accepted:
            lock.lock()
            resetLocked()
            lock.unlock()
        case .rejected:
            fireOnce()
        }
    }

    /// The HTTP status of a REST request that carried this device's token.
    public func noteResponse(status: Int) {
        let shouldFire: Bool
        lock.lock()
        switch status {
        case 401:
            let at = now()
            if firstRejectionAt == nil { firstRejectionAt = at }
            consecutiveRejections += 1
            shouldFire = consecutiveRejections >= rejectionThreshold
                && at - (firstRejectionAt ?? at) >= minimumSpan
        case 429, 500...:
            shouldFire = false
        default:
            resetLocked()
            shouldFire = false
        }
        lock.unlock()
        if shouldFire { fireOnce() }
    }

    /// Stops this monitor from ever firing (sign-out already under way).
    public func cancel() {
        lock.lock()
        armed = false
        lock.unlock()
    }

    private func resetLocked() {
        consecutiveRejections = 0
        firstRejectionAt = nil
    }

    private func fireOnce() {
        lock.lock()
        guard armed, !fired else {
            lock.unlock()
            return
        }
        fired = true
        lock.unlock()
        onRevoked()
    }
}

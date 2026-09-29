import Foundation
import GRDB
import os

/// Decides when this process's SQLite databases must give up their file
/// locks, so iOS never suspends the app while it holds one.
///
/// Why this exists: both databases the iPhone app writes — the journal
/// mirror and the search index — live in the `group.chat.matron` App Group
/// container, and iOS terminates a process that is suspended while holding a
/// lock on a file there (RUNNINGBOARD `0xdead10cc`). Eight such kills were
/// pulled from a single phone across builds 1.0.4 → 1.2.0, each with a
/// `GRDB.DatabaseQueue` thread mid-`sqlite3_step` at suspension time.
///
/// The mechanism is GRDB's own: databases opened with
/// `Configuration.observesSuspensionNotifications` interrupt whatever they
/// are running when `Database.suspendNotification` is posted, roll back any
/// open transaction at their next locking statement, and refuse every new
/// write (and every read outside WAL mode) with `SQLITE_ABORT` /
/// `SQLITE_INTERRUPT` until `Database.resumeNotification`. Callers see those
/// as ordinary thrown write errors, and the ones that matter already treat a
/// thrown write as "nothing happened": the journal cursor advances inside the
/// same transaction as the event insert, so a refused frame is simply
/// replayed after the next reconnect.
///
/// What this type adds is WHEN. Suspending on every background transition
/// would break the work the app legitimately does in the background — the
/// BGAppRefresh catch-up and the outbox grace window both write the journal
/// with the app backgrounded. So the rule is: databases run while the app is
/// in the foreground or any background activity is in flight, and are
/// suspended the moment the app is in the background with none. Each
/// background entry point claims an `Activity` for its lifetime and ends it
/// in its normal AND its expiration path; the expiration path is the one that
/// matters, because iOS suspends the process right after it returns.
///
/// Thread-safe and synchronous on purpose: a background task's expiration
/// handler must have released the locks by the time it returns, and
/// `BGTask.expirationHandler` is not guaranteed to run on the main thread, so
/// an actor or main-actor hop would release them too late. Transitions are
/// applied inside the state lock so two racing callers can never post
/// suspend/resume out of order; the default `apply` only posts GRDB's
/// notifications, whose observers flip a flag and call `sqlite3_interrupt`
/// without ever calling back into this type.
public final class DatabaseSuspensionController: @unchecked Sendable {
    /// The process-wide instance the iOS app drives. GRDB's suspension
    /// notifications are process-global too — one post suspends every
    /// database that observes them — so a single decision point mirrors the
    /// mechanism it controls. Tests build their own instances.
    public static let shared = DatabaseSuspensionController()

    /// A claim that background work which may touch a database is in flight.
    /// `end()` is idempotent, so a task's expiration handler and its normal
    /// completion can both call it without double-releasing.
    public final class Activity: @unchecked Sendable {
        fileprivate let id: Int
        public let name: String
        private weak var controller: DatabaseSuspensionController?

        fileprivate init(id: Int, name: String, controller: DatabaseSuspensionController) {
            self.id = id
            self.name = name
            self.controller = controller
        }

        public func end() {
            controller?.endActivity(id: id)
        }
    }

    private struct State {
        var inBackground = false
        var activities: [Int: String] = [:]
        var nextActivityID = 0
        /// Whether `apply(true)` was the last transition applied. Starts
        /// `false` because a freshly opened GRDB database is not suspended.
        var suspended = false

        var shouldSuspend: Bool { inBackground && activities.isEmpty }
    }

    private static let logger = os.Logger(subsystem: "chat.matron", category: "db-suspension")

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let apply: @Sendable (_ suspend: Bool) -> Void
    private let resumeHandler = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    /// - Parameter apply: performs a transition — `true` suspends, `false`
    ///   resumes. Only ever called on an actual change (plus the explicit
    ///   re-assert in `databaseDidOpen()`). The default posts GRDB's
    ///   notifications; tests inject a recorder.
    public init(apply: @escaping @Sendable (_ suspend: Bool) -> Void = DatabaseSuspensionController.postGRDBNotification) {
        self.apply = apply
    }

    /// GRDB's own suspend/resume broadcast, received by every database
    /// opened with `observesSuspensionNotifications`.
    public static func postGRDBNotification(suspend: Bool) {
        NotificationCenter.default.post(
            name: suspend ? Database.suspendNotification : Database.resumeNotification, object: nil)
    }

    /// Installs a hook run after every resume — the iOS host flushes the
    /// search writes that were refused while suspended. Runs outside the
    /// state lock, on whichever thread caused the resume; it should only
    /// schedule work.
    public func setResumeHandler(_ handler: @escaping @Sendable () -> Void) {
        resumeHandler.withLock { $0 = handler }
    }

    /// Whether the databases are currently suspended.
    public var isSuspended: Bool {
        state.withLock { $0.suspended }
    }

    /// Names of the background activities currently holding the databases
    /// open — diagnostics only.
    public var activeActivityNames: [String] {
        state.withLock { $0.activities.values.sorted() }
    }

    /// Records a foreground/background transition. Entering the foreground
    /// resumes at once; entering the background suspends unless an activity
    /// is in flight — so a caller that starts background work in response to
    /// the same transition must `beginActivity` BEFORE calling this, or the
    /// work's first writes land in a suspend/resume blip.
    public func setInBackground(_ inBackground: Bool) {
        update { $0.inBackground = inBackground }
    }

    /// Claims the databases for a piece of background work. Resumes them if
    /// they were suspended (a BGAppRefresh wake arrives with them suspended
    /// from the previous background transition).
    public func beginActivity(named name: String) -> Activity {
        let id = update { state -> Int in
            let id = state.nextActivityID
            state.nextActivityID += 1
            state.activities[id] = name
            return id
        }
        return Activity(id: id, name: name, controller: self)
    }

    /// Re-asserts the current decision on a database that was just opened.
    /// GRDB suspension is per-connection state set when the notification is
    /// posted: a database opened AFTER the last `suspendNotification` starts
    /// unsuspended and would hold its locks straight into the next
    /// suspension. Posting again is harmless for the databases that were
    /// already suspended (GRDB's `suspend()` is idempotent).
    public func databaseDidOpen() {
        state.withLockUnchecked { state in
            if state.suspended { apply(true) }
        }
    }

    private func endActivity(id: Int) {
        update { $0.activities.removeValue(forKey: id) }
    }

    /// Applies `mutate`, then performs the suspend/resume transition the new
    /// state calls for (if any) while still holding the lock. The resume
    /// hook runs after the lock is released.
    @discardableResult
    private func update<R>(_ mutate: (inout State) -> R) -> R {
        let (result, resumed) = state.withLockUnchecked { state -> (R, Bool) in
            let result = mutate(&state)
            let target = state.shouldSuspend
            guard target != state.suspended else { return (result, false) }
            state.suspended = target
            let inBackground = state.inBackground
            let activities = state.activities.values.sorted()
            Self.logger.info("databases \(target ? "suspended" : "resumed", privacy: .public); background=\(inBackground) activities=\(activities, privacy: .public)")
            apply(target)
            return (result, !target)
        }
        if resumed, let handler = resumeHandler.withLock({ $0 }) { handler() }
        return result
    }
}

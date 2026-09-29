import UIKit
import MatronJournal

/// Send-then-pocket cover: when the app backgrounds with queued sends
/// still awaiting delivery confirmation, hold a `UIApplication`
/// background task open so the engine's flush (and, if the network just
/// came back, its reconnect) gets a real grace window instead of the
/// process suspending mid-send. Bounded well inside the ~30s the system
/// grants; ends early the moment the outbox drains.
///
/// The hold is also a `DatabaseSuspensionController` activity: the flush and
/// its delivery confirmations write the journal, so the databases stay
/// resumed for exactly as long as the background task is open, and are
/// suspended the moment it ends — normally or by expiration.
@MainActor
enum OutboxBackgroundGrace {
    private static let maxHold: TimeInterval = 20

    /// Must run BEFORE the caller reports the background transition to
    /// `DatabaseSuspensionController`, so the activity is already claimed
    /// when the controller decides whether to suspend.
    static func holdIfNeeded(engine: JournalSyncEngine?) {
        guard let engine else { return }
        // One mutable box per hold so the expiration handler and the
        // normal end can't double-end the task.
        final class Token {
            var id: UIBackgroundTaskIdentifier = .invalid
            var activity: DatabaseSuspensionController.Activity?

            func end() {
                // Databases first: once the task ends iOS may suspend at any
                // moment, and the locks have to be gone by then.
                activity?.end()
                activity = nil
                guard id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        let token = Token()
        token.activity = DatabaseSuspensionController.shared.beginActivity(named: "outbox-grace")
        token.id = UIApplication.shared.beginBackgroundTask(withName: "chat.matron.outbox-flush") {
            // The system calls this synchronously on the main thread and
            // suspends right after it returns — so end here, not in a Task
            // hop that would run after the suspension it exists to prepare.
            MainActor.assumeIsolated { token.end() }
        }
        guard token.id != .invalid else {
            token.end()
            return
        }
        Task {
            let deadline = Date().addingTimeInterval(maxHold)
            while Date() < deadline, await engine.hasPendingOutbox {
                try? await Task.sleep(for: .seconds(1))
            }
            token.end()
        }
    }
}

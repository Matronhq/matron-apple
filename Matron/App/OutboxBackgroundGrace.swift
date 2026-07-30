import UIKit
import MatronJournal

/// Send-then-pocket cover: when the app backgrounds with queued sends
/// still awaiting delivery confirmation, hold a `UIApplication`
/// background task open so the engine's flush (and, if the network just
/// came back, its reconnect) gets a real grace window instead of the
/// process suspending mid-send. Bounded well inside the ~30s the system
/// grants; ends early the moment the outbox drains.
@MainActor
enum OutboxBackgroundGrace {
    private static let maxHold: TimeInterval = 20

    static func holdIfNeeded(engine: JournalSyncEngine?) {
        guard let engine else { return }
        // One mutable box per hold so the expiration handler and the
        // normal end can't double-end the task.
        final class Token { var id: UIBackgroundTaskIdentifier = .invalid }
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "chat.matron.outbox-flush") {
            Task { @MainActor in
                guard token.id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(token.id)
                token.id = .invalid
            }
        }
        guard token.id != .invalid else { return }
        Task {
            let deadline = Date().addingTimeInterval(maxHold)
            while Date() < deadline, await engine.hasPendingOutbox {
                try? await Task.sleep(for: .seconds(1))
            }
            guard token.id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(token.id)
            token.id = .invalid
        }
    }
}

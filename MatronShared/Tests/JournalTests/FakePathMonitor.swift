import Foundation
@testable import MatronJournal

/// A path monitor the test drives: nothing reports until `deliver` is called,
/// so a test never depends on the host's network. Delivery still works after
/// `cancel()`, to model a callback that was already in flight.
final class FakePathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool, String) -> Void)?
    private var _isCancelled = false

    func start(onUpdate: @escaping @Sendable (Bool, String) -> Void) {
        lock.withLock { handler = onUpdate }
    }

    func cancel() {
        lock.withLock { _isCancelled = true }
    }

    var isCancelled: Bool { lock.withLock { _isCancelled } }

    func deliver(satisfied: Bool, signature: String) {
        let handler = lock.withLock { self.handler }
        handler?(satisfied, signature)
    }
}

/// Hands the engine a `FakePathMonitor` per start and keeps them, oldest first.
final class FakePathMonitors: @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [FakePathMonitor] = []
    var made: [FakePathMonitor] { lock.withLock { _made } }

    var factory: @Sendable () -> any NetworkPathMonitoring {
        { [self] in
            let monitor = FakePathMonitor()
            lock.withLock { _made.append(monitor) }
            return monitor
        }
    }
}

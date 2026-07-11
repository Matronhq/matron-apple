import Foundation
import MatronJournal

/// Bridges `JournalSyncEngine` into the `SyncService` protocol.
///
/// Only `start()` / `stop()` need wrapper bodies here:
/// - `isRunning: Bool { get async }` is satisfied directly by the actor's
///   `isRunning` property — actor isolation makes any access from outside
///   the actor implicitly `async`.
/// - `waitUntilReady() async throws` is satisfied directly; the engine's
///   method already has that exact signature.
/// - `stateStream() async -> AsyncStream<SyncConnectionState>` is satisfied
///   directly too: the engine's method is `nonisolated` and synchronous,
///   but a synchronous function can satisfy an `async` protocol
///   requirement.
/// `start()` / `stop()` need wrappers because the engine deliberately uses
/// different names (`beginSync()` / `endSync()`) so this conformance can be
/// layered on without colliding with the engine's own lifecycle methods.
extension JournalSyncEngine: SyncService {
    public func start() async throws {
        beginSync()
    }

    public func stop() async {
        await endSync()
    }
}

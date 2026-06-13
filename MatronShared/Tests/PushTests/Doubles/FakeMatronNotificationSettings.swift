import Foundation
import MatrixRustSDK
@testable import MatronPush

/// Records every `setRoomNotificationMode` call into an in-memory dict
/// so tests can assert what was written without standing up a live
/// homeserver. Per-room override of `failingRoomIDs` lets a test
/// simulate a per-room SDK failure (so `PushBootstrap` can prove it
/// continues past one bad room rather than poisoning the rest).
///
/// `final class` (not actor) because tests await all mutations
/// serially; a lock would be ceremony for no benefit. `@unchecked
/// Sendable` for the same reason — same convention as the rest of
/// MatronShared's test doubles.
final class FakeMatronNotificationSettings: MatronNotificationSettings, @unchecked Sendable {
    /// Per-room mode sink. Last-write-wins on duplicate sets.
    var modes: [String: RoomNotificationMode] = [:]

    /// Room IDs whose `setRoomNotificationMode` call should throw the
    /// `simulatedFailure` error. Empty by default (every call succeeds).
    var failingRoomIDs: Set<String> = []

    enum SimulatedError: Error { case forced }

    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        if failingRoomIDs.contains(roomId) {
            throw SimulatedError.forced
        }
        modes[roomId] = mode
    }
}

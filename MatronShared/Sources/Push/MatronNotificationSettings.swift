import Foundation
import MatrixRustSDK

/// Minimal in-house wrapper around the SDK's `NotificationSettings` so
/// `PushBootstrap` can swap in a fake for unit tests. Named with the
/// `Matron` prefix to disambiguate from the SDK's own
/// `NotificationSettingsProtocol` (which has 30+ methods we don't need
/// and would have to implement on every test fake).
///
/// Today this protocol carries one method — Phase 4 only needs the
/// per-room mode setter. Add to it as future Push tasks (Mac
/// MacNotificationHandler, in-app notification settings UI) call
/// further surface area.
public protocol MatronNotificationSettings: Sendable {
    /// Sets the room's notification mode on the homeserver. `.allMessages`
    /// is what spec §8.2's "notify on every event in joined rooms"
    /// resolves to — the SDK then emits `notify` actions for every
    /// timeline event in the room, which Sygnal fans out as APNs
    /// pushes. Throws on network / SDK failure.
    func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws
}

/// Live impl wrapping the SDK's `NotificationSettings` instance returned
/// from `Client.getNotificationSettings()`. Built once per session via
/// `from(client:)` so the underlying handle is reused across calls.
public struct LiveMatronNotificationSettings: MatronNotificationSettings {
    private let underlying: NotificationSettings

    private init(underlying: NotificationSettings) {
        self.underlying = underlying
    }

    /// `Client.getNotificationSettings()` is async (the SDK loads the
    /// rules off the homeserver) but doesn't throw — so the factory
    /// returns directly rather than throwing.
    public static func from(client: Client) async -> LiveMatronNotificationSettings {
        LiveMatronNotificationSettings(underlying: await client.getNotificationSettings())
    }

    public func setRoomNotificationMode(roomId: String, mode: RoomNotificationMode) async throws {
        try await underlying.setRoomNotificationMode(roomId: roomId, mode: mode)
    }
}

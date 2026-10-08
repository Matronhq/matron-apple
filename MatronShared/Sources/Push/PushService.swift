import Foundation

/// Cross-platform surface for managing the Matrix push pipeline. Same
/// protocol on iOS (where registration happens after the host app
/// boots and tokens flow through `UIApplicationDelegate`) and on Mac
/// (where `NSApplicationDelegate` does the same — see Task 11's
/// `MacPushBootstrap`).
///
/// The live implementation (`PushServiceLive`, Task 2) bridges to the
/// SDK's `notificationClient(processSetup:).setHttpPusher(...)`. Tests
/// inject a fake conforming to this protocol so call-site code can
/// stay platform-neutral and async-pure.
public protocol PushService: Sendable {
    /// Requests notification permission via
    /// `UNUserNotificationCenter.requestAuthorization`. Returns `true`
    /// on grant, `false` on decline OR error — the OS-level error
    /// here is not actionable from the app side, so the indistinct
    /// return shape mirrors what every Matrix client does.
    func requestPermission() async -> Bool

    /// Registers a device token + Sygnal pusher URL with the user's
    /// homeserver. Idempotent: calling again with the same `(token,
    /// pusherBaseURL)` pair is a no-op on the server side. Throws on
    /// network / SDK failure so the caller can decide between retry
    /// and surfacing an error to the user.
    func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws

    /// Removes the pusher record from the homeserver. Called from the
    /// sign-out path (Task 8) so a logged-out account doesn't continue
    /// receiving APNs traffic on the same device.
    func unregister(deviceToken: Data, pusherBaseURL: URL) async throws
}

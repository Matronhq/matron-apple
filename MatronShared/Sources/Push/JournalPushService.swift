import Foundation
import UserNotifications
import MatronJournal

/// `PushService` implementation backed by the journal server's
/// `/push/register` endpoint (`JournalAPI.registerPush` /
/// `unregisterPush`), replacing `PushServiceLive`'s SDK-side
/// `setPusher`/`deletePusher` calls now that push registration is a plain
/// journal-server concern.
///
/// `@unchecked Sendable` for the same reason as `PushServiceLive`: the only
/// stored state is a value type (`JournalAPI` is an actor reference, safe
/// to share) plus a `Sendable` enum, but nothing here actually needs the
/// opt-out — kept for parity with the sibling live service.
public final class JournalPushService: PushService, @unchecked Sendable {
    private let api: JournalAPI
    private let environment: JournalAPI.PushEnvironment

    /// The app decides sandbox vs. prod (`#if DEBUG` → `.sandbox`, else
    /// `.prod`) at the call site in a later task; this service just
    /// forwards whichever environment it's constructed with.
    public init(api: JournalAPI, environment: JournalAPI.PushEnvironment) {
        self.api = api
        self.environment = environment
    }

    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    /// `pusherBaseURL` is part of the legacy `PushService` protocol
    /// signature (the Sygnal pusher URL); the journal server doesn't need
    /// it — registration is keyed on the authenticated device alone — so
    /// its value is ignored here.
    public func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws {
        try await api.registerPush(tokenHex: Self.hexString(from: deviceToken), environment: environment)
    }

    public func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {
        try await api.unregisterPush()
    }

    /// Hex-encodes APNs device tokens for the journal server's
    /// `apns_token` field. `internal` (not `private`) so the unit test can
    /// pin the encoding without spinning up `UNUserNotificationCenter`.
    static func hexString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

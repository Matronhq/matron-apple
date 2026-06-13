import Foundation
import UserNotifications
import MatrixRustSDK
import MatronModels
import MatronSync
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Live `PushService` implementation. Bridges the protocol surface to
/// `Client.setPusher(...)` / `Client.deletePusher(...)` on the SDK.
///
/// Note: the original Phase 4 plan routed `setPusher` / `deletePusher`
/// through `client.notificationClient(processSetup:)` — that's wrong
/// for v26 of `matrix-rust-components-swift`. Pusher registration
/// lives on `Client` directly; the `notificationClient` surface is
/// only for fetching + decoding incoming notification events
/// (Task 3's `PushDecoder`).
///
/// `@unchecked Sendable` because the live impl holds an actor
/// (`ClientProvider`) and a value type (`UserSession`), but Swift's
/// generated conformance check trips on the SDK's `Client` reference
/// returned by `provider.client(for:)`. The reference is used only
/// inside the async functions below and never stored on `self`.
public final class PushServiceLive: PushService, @unchecked Sendable {
    private let provider: ClientProvider
    private let session: UserSession

    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    public func requestPermission() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    public func registerToken(_ deviceToken: Data, pusherBaseURL: URL) async throws {
        let client = try await provider.client(for: session)
        let tokenHex = Self.hexEncoded(deviceToken)
        try await client.setPusher(
            identifiers: PusherIdentifiers(
                pushkey: tokenHex,
                appId: PushConfig.appID
            ),
            kind: .http(data: HttpPusherData(
                url: pusherBaseURL.absoluteString,
                format: PushConfig.pushFormat,
                defaultPayload: nil
            )),
            appDisplayName: PushConfig.appDisplayName,
            deviceDisplayName: Self.deviceDisplayName(),
            profileTag: nil,
            lang: PushConfig.language
        )
    }

    public func unregister(deviceToken: Data, pusherBaseURL: URL) async throws {
        let client = try await provider.client(for: session)
        let tokenHex = Self.hexEncoded(deviceToken)
        try await client.deletePusher(
            identifiers: PusherIdentifiers(
                pushkey: tokenHex,
                appId: PushConfig.appID
            )
        )
    }

    /// Hex-encodes APNs device tokens for the Matrix `pushkey` field.
    /// Sygnal expects the lowercase hex string of the raw token bytes
    /// — the server adds the bundle topic + sandbox flag from the
    /// `app_id` mapping. `internal` (not `private`) so the unit test
    /// can pin the encoding without spinning up the full pipeline.
    static func hexEncoded(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Best-effort device display name reported to Sygnal so the user
    /// can identify which physical device a pusher record belongs to
    /// in the homeserver UI. iOS returns the user-set device name
    /// (or the marketing name on iOS 16+ without the Personal
    /// Information entitlement). Mac returns the local hostname.
    static func deviceDisplayName() -> String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

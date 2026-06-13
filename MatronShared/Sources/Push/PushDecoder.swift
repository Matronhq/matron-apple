import Foundation
import MatrixRustSDK
import MatronModels
import MatronStorage
import MatronSync

/// User-facing payload built by `PushDecoder.decode(...)` and surfaced
/// by the iOS NSE / Mac in-process delegate. `threadIdentifier` becomes
/// `UNNotificationContent.threadIdentifier` so iOS groups consecutive
/// pushes from the same room into a single thread; `badge` is filled
/// later by `MacNotificationHandler` (Task 10) using the unread count
/// from the live `chatSummaries()` stream.
public struct DecodedNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    public let threadIdentifier: String?
    public let badge: Int?

    public init(title: String, body: String, threadIdentifier: String?, badge: Int?) {
        self.title = title
        self.body = body
        self.threadIdentifier = threadIdentifier
        self.badge = badge
    }
}

/// Bridges an APNs silent payload (room ID + event ID) to a decrypted
/// `DecodedNotification`. Used by:
///
/// - **iOS NSE** (Task 4) — runs in the extension process, calls
///   `live(provider:session:).decode(roomID:eventID:)` to fetch +
///   decrypt the event off the App-Group-shared crypto store.
/// - **Mac in-process delegate** (Task 10) — runs inside the host app,
///   reuses the same `live(...)` factory so the body-construction logic
///   doesn't drift between platforms.
///
/// `Fetcher` is closure-injectable so unit tests can drive `decode(...)`
/// without standing up a homeserver. Production wiring is `live(...)`.
public final class PushDecoder: @unchecked Sendable {
    public typealias Fetcher = (_ roomID: String, _ eventID: String) async throws -> NotificationItem?

    private let fetcher: Fetcher

    public init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    /// Production fetcher: resolves a Client through `provider`, opens
    /// a `NotificationClient` against the shared crypto store, and
    /// fetches the notification for `(roomId, eventId)`.
    ///
    /// Caller passes `processSetup` explicitly because the right value
    /// is platform- and surface-specific:
    ///
    /// - **iOS NSE** uses `.multipleProcesses` — the .appex runs in a
    ///   distinct process and needs cross-process coordination on the
    ///   App-Group-shared crypto store.
    /// - **Mac in-process handler** uses `.singleProcess(syncService:)`
    ///   — the host app is the only consumer of the crypto store, but
    ///   it needs to coordinate with the running SyncService so the
    ///   notification client doesn't conflict with the live sync's
    ///   crypto-store writes. The associated value is the SDK's
    ///   `MatrixRustSDK.SyncService` from
    ///   `SyncServiceLive.sdkService()`.
    public static func live(
        provider: ClientProvider,
        session: UserSession,
        processSetup: NotificationProcessSetup
    ) -> PushDecoder {
        PushDecoder { roomID, eventID in
            let client = try await provider.client(for: session)
            let nc = try await client.notificationClient(processSetup: processSetup)
            let status = try await nc.getNotification(roomId: roomID, eventId: eventID)
            switch status {
            case .event(let item):
                return item
            case .eventNotFound, .eventFilteredOut, .eventRedacted:
                return nil
            }
        }
    }

    /// Top-level entry point. Returns the fallback payload if the
    /// fetcher yields nil (event not found, filtered out, redacted, OR
    /// the SDK couldn't decrypt in time) — never throws on those paths
    /// so the NSE can always deliver SOMETHING to the user.
    public func decode(roomID: String, eventID: String) async throws -> DecodedNotification {
        guard let item = try await fetcher(roomID, eventID) else {
            return Self.fallback(roomID: roomID)
        }
        return Self.decoded(from: item, roomID: roomID)
    }

    /// "Couldn't decrypt / find the event" fallback. The encrypted
    /// placeholder body that APNs already shows is replaced with a
    /// neutral "New message" so the user sees consistent copy across
    /// the encrypted-but-fetchable and encrypted-and-stuck paths. No
    /// plaintext leaks via this surface.
    static func fallback(roomID: String) -> DecodedNotification {
        DecodedNotification(
            title: "Matron",
            body: "New message",
            threadIdentifier: roomID,
            badge: nil
        )
    }

    /// Maps a fetched `NotificationItem` to the user-facing payload.
    /// `decoded(from:roomID:)` is reachable in tests only via a real
    /// fetcher that stands up a NotificationItem with a Rust-handle-
    /// backed `TimelineEvent` — the integration harness exercises that
    /// path. Unit tests cover the leaf `body(for*:)` extractors below
    /// instead, which are pure functions on publicly-constructible
    /// SDK enums.
    static func decoded(from item: NotificationItem, roomID: String) -> DecodedNotification {
        let title = item.senderInfo.displayName ?? Self.senderID(of: item)
        let body: String
        do {
            body = try Self.body(for: item.event)
        } catch {
            body = "New message"
        }
        return DecodedNotification(
            title: title,
            body: body,
            threadIdentifier: item.threadId ?? roomID,
            badge: nil
        )
    }

    static func senderID(of item: NotificationItem) -> String {
        switch item.event {
        case .timeline(let event): return event.senderId()
        case .invite(let sender): return sender
        }
    }

    /// Calls into the SDK's `TimelineEvent.content()` — `throws` because
    /// the Rust side can fail to decrypt a still-encrypted event whose
    /// keys haven't arrived yet. Callers map the throw to the fallback
    /// body so APNs always delivers a notification.
    static func body(for event: NotificationEvent) throws -> String {
        switch event {
        case .invite:
            return "Invited you to a room"
        case .timeline(let timelineEvent):
            return body(forContent: try timelineEvent.content())
        }
    }

    /// Pure (no FFI) — testable.
    static func body(forContent content: TimelineEventContent) -> String {
        switch content {
        case .messageLike(let messageContent):
            return body(forMessageLike: messageContent)
        case .state:
            return "State changed"
        }
    }

    /// Pure (no FFI) — testable. Every `MessageLikeEventContent` case is
    /// handled exhaustively so a future SDK addition (a new call type,
    /// a new key-verification phase) fails to compile here instead of
    /// silently falling through to a generic body.
    static func body(forMessageLike content: MessageLikeEventContent) -> String {
        switch content {
        case .roomMessage(let messageType, _):
            return body(forMessageType: messageType)
        case .roomEncrypted:
            return "🔒 Encrypted message"
        case .reactionContent:
            return "Reacted to message"
        case .sticker:
            return "Sticker"
        case .poll(let question):
            return "📊 \(question)"
        case .roomRedaction:
            return "Message redacted"
        case .callInvite, .callAnswer, .callHangup, .callCandidates, .rtcNotification:
            return "📞 Call"
        case .keyVerificationReady, .keyVerificationStart, .keyVerificationCancel,
             .keyVerificationAccept, .keyVerificationKey, .keyVerificationMac, .keyVerificationDone:
            return "Verification update"
        }
    }

    /// Pure (no FFI) — testable. Image / file / audio / video bodies
    /// prefer the user-set `caption` field (Element X iOS does the
    /// same), falling back to `filename` so the user always sees
    /// SOMETHING identifying the attachment. `.gallery` uses `body`
    /// because the SDK's GalleryMessageContent doesn't carry a
    /// caption field. `.other` returns the raw body so spec §10's
    /// custom event types (`chat.matron.tool_call`,
    /// `chat.matron.ask_user`) render their pre-formatted body
    /// strings unchanged.
    static func body(forMessageType messageType: MessageType) -> String {
        switch messageType {
        case .text(let content): return content.body
        case .notice(let content): return content.body
        case .emote(let content): return "* \(content.body)"
        case .image(let content): return "📷 \(content.caption ?? content.filename)"
        case .file(let content): return "📎 \(content.caption ?? content.filename)"
        case .audio(let content): return "🎙 \(content.caption ?? content.filename)"
        case .video(let content): return "🎬 \(content.caption ?? content.filename)"
        case .gallery(let content): return "🖼 \(content.body)"
        case .location: return "📍 Location"
        case .other(_, let body): return body
        }
    }
}

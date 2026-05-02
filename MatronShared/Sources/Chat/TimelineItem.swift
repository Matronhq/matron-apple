import Foundation

/// DTO consumed by the UI for a single timeline row.
///
/// Wraps the SDK's opaque `MatrixRustSDK.TimelineItem` (which is a Rust handle)
/// in a small, value-typed Swift enum so views, view-models, and tests don't
/// need to touch FFI types. `id` is the SDK's `TimelineUniqueId.id` — stable
/// across the local-echo → remote-event transition, so list-diffing in
/// SwiftUI stays smooth as a sent message is acknowledged by the homeserver.
public struct TimelineItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let sender: String
    public let timestamp: Date
    public let kind: Kind
    /// `true` if the local user sent this event.
    public let isOwn: Bool
    public let sendState: SendState

    public enum Kind: Equatable, Sendable {
        case text(body: String, formattedHTML: String?)
        case image(url: URL?, caption: String?, sizeBytes: Int64?)
        case file(url: URL?, filename: String, sizeBytes: Int64?)
        /// Member joins, name changes, profile updates — anything that's a
        /// state event we still want to render as a small inline notice.
        case stateChange(text: String)
        /// Catch-all for events we don't render specially yet (encrypted but
        /// undecryptable, polls, stickers, etc.). UI shows a placeholder so
        /// the event isn't silently dropped.
        case unknown(eventType: String)
    }

    public enum SendState: Equatable, Sendable {
        case sent
        case sending
        case failed(reason: String)
    }

    public init(
        id: String,
        sender: String,
        timestamp: Date,
        kind: Kind,
        isOwn: Bool,
        sendState: SendState = .sent
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.kind = kind
        self.isOwn = isOwn
        self.sendState = sendState
    }
}

import Foundation
import MatronEvents
import MatronModels

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
        /// `chat.matron.tool_call` event (spec §4.1). Phase 5 — renders
        /// as a `ToolCallCard` (Task 8). `eventID` is the underlying
        /// Matrix event ID, kept on the case so `m.replace` updates
        /// can be correlated against an in-flight running tool call.
        case toolCall(eventID: String, ToolCallEvent)
        /// `chat.matron.ask_user` event (spec §4.2). Phase 5 — renders
        /// as a half-sheet on iOS / fixed-size sheet on Mac (Task 9).
        /// `eventID` is the underlying Matrix event ID, used by the
        /// sheet's reply path to set `m.in_reply_to` so the bot can
        /// correlate the answer.
        case askUser(eventID: String, AskUserEvent)
        /// Catch-all for events we don't render specially yet (encrypted but
        /// undecryptable, polls, stickers, etc.). UI shows a placeholder so
        /// the event isn't silently dropped.
        case unknown(eventType: String)
    }

    /// Source compatibility shim — the enum lives in `MatronModels` as
    /// `TimelineSendState` so `MatronDesignSystem` can bridge it without
    /// transitively pulling `MatrixRustSDK`. Existing call sites
    /// referencing `TimelineItem.SendState` keep compiling unchanged.
    public typealias SendState = TimelineSendState

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

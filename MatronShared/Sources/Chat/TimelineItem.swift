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
    /// Event ID this message replies to (`m.in_reply_to`), if any.
    /// Phase 5: lets `ChatViewModel.pendingAsk()` mark an `ask_user`
    /// prompt answered when a reply targeting it appears in the
    /// timeline — including replies sent from the user's other
    /// devices, which per-device `UserDefaults` bookkeeping can't see.
    public let inReplyToEventID: String?

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
        /// A live command-output announcement (journal `tool_output` with a
        /// `viewer_url`). Renders as a `LiveOutputCard` that streams the
        /// command's output from the bridge's viewer WebSocket — the
        /// journal-protocol port of matron-web's live-output tile.
        case liveOutput(eventID: String, LiveOutputEvent)
        /// `chat.matron.ask_user` event (spec §4.2). Phase 5 — renders
        /// as a half-sheet on iOS / fixed-size sheet on Mac (Task 9).
        /// `eventID` is the underlying Matrix event ID, used by the
        /// sheet's reply path to set `m.in_reply_to` so the bot can
        /// correlate the answer.
        case askUser(eventID: String, AskUserEvent)
        /// A `chat.matron.button_response` answer to a buttons prompt
        /// (Matron X protocol). `promptEventID` is the buttons event
        /// this answers (from the `chat.matron.button_answer`
        /// relation). NOT rendered — Matron X hides button responses
        /// from the timeline entirely, own and others' — but kept in
        /// the snapshot so `ChatViewModel.pendingAsk()` can mark the
        /// prompt answered across devices.
        case askUserAnswer(promptEventID: String, selectedValues: [String])
        /// Transient typing / tool-use indicator (matron-journal `activity`
        /// ephemeral). Not persisted and not part of history — appended as a
        /// trailing overlay row while the agent is thinking or running a
        /// tool, and dropped when it goes idle or the stream goes stale.
        case activityIndicator(label: String)
        /// Live tool-output overlay (journal `tool_stream` ephemerals) — a
        /// terminal tile streaming a running command's output at the bottom
        /// of the timeline. Not persisted; retired when the durable
        /// `tool_output` row with the same `messageRef` lands (which renders
        /// as `.toolCall`). `command` is nil until a `sync` frame supplies
        /// meta — appends never carry it.
        case toolStreamLive(messageRef: String, command: String?, text: String, headTruncated: Bool)
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
        sendState: SendState = .sent,
        inReplyToEventID: String? = nil
    ) {
        self.id = id
        self.sender = sender
        self.timestamp = timestamp
        self.kind = kind
        self.isOwn = isOwn
        self.sendState = sendState
        self.inReplyToEventID = inReplyToEventID
    }
}

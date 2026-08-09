import Foundation
import MatronModels

/// One TOC entry from a bridge summary pass, as consumed by the Chat layer.
/// Mirrors the Journal module's `SummaryEntryRecord` but lives here so Chat
/// doesn't have to depend on the Journal record type — `JournalTimelineService`
/// maps store rows into this shape at the boundary.
public struct ConversationSummaryEntry: Equatable, Sendable, Identifiable {
    public let seq: Int64
    public let toc: String
    public let detail: String
    public let date: Date

    public init(seq: Int64, toc: String, detail: String, date: Date) {
        self.seq = seq
        self.toc = toc
        self.detail = detail
        self.date = date
    }

    public var id: Int64 { seq }
}

/// Per-room timeline access. One `TimelineService` per open room.
///
/// `items()` is the read side: an `AsyncStream` of full snapshots, newest
/// item last. The live impl rebuilds each snapshot by applying SDK
/// `TimelineDiff`s to an in-memory ordered map keyed by event id, so
/// SwiftUI list-diffing stays cheap as messages arrive.
///
/// The send and pagination methods are the write side; they delegate
/// straight to the SDK's `Timeline` and return once the SDK has accepted
/// the request (server-side delivery confirmation arrives later through
/// `items()` when the local echo is replaced by the remote event).
public protocol TimelineService: Sendable {
    /// AsyncStream of full timeline snapshots. Newest item last.
    ///
    /// `AsyncThrowingStream` so sync-readiness failures and SDK
    /// resolution errors (`TimelineServiceError.roomNotFound`) bubble to
    /// the consumer instead of being swallowed by `continuation.finish()`
    /// — `ChatViewModel` surfaces the message in `error` so the View can
    /// render a banner / `ContentUnavailableView` overlay (QA finding #10).
    func items() -> AsyncThrowingStream<[TimelineItem], Error>

    /// Sends a plain text message. Body may include markdown.
    /// Returns when the SDK has accepted the send (not when the server confirms it).
    ///
    /// When `inReplyTo` is non-nil the wire content carries
    /// `m.relates_to.m.in_reply_to.event_id` (the SDK's `sendReply`
    /// adds the rich-reply fallback automatically) so a bot can
    /// correlate the message with the prompt it answers — the
    /// `chat.matron.ask_user` reply contract (spec §4.2).
    func sendText(_ body: String, inReplyTo: String?) async throws

    /// Sends a `chat.matron.button_response` answer to a
    /// `chat.matron.buttons` prompt (the live bridge / Matron X
    /// protocol — see `AskUserEvent.ReplyChannel.buttonResponse`).
    /// `selectedValues` carries the chosen buttons' wire `value`
    /// fields; the plaintext fallback `body` is the values joined
    /// with ", " — byte-compatible with Matron X's
    /// `TimelineController.sendButtonResponse`.
    func sendButtonResponse(selectedValues: [String], inReplyTo promptEventID: String) async throws

    /// Sends an image attachment as an `m.image` event.
    ///
    /// `caption` is the composer text the attachment left with. It rides on
    /// the event itself rather than following as a separate message so the
    /// agent receives the picture and the sentence explaining it as ONE
    /// prompt — the bridge's upload annotation puts the caption above the
    /// file path (see the bridge's `lib/iv-uploads.js`).
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?) async throws

    /// Sends a file attachment as an `m.file` event. `caption` behaves
    /// exactly as it does for `sendImage`.
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?) async throws

    /// Progress-reporting variants: `progress` receives the uploaded
    /// fraction (0…1), off-main. Protocol requirements (not extension-only
    /// overloads) so calls through `any TimelineService` dispatch to the
    /// real implementation; the extension defaults forward to the plain
    /// versions so fakes and outbox-less implementations compile unchanged.
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?,
                   progress: (@Sendable (Double) -> Void)?) async throws
    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?,
                  progress: (@Sendable (Double) -> Void)?) async throws

    /// Asks the SDK to paginate older history. UI subscribes via `items()`.
    /// Returns `true` if the SDK has reached the start of the room's
    /// history (further calls would be no-ops); `false` otherwise. The
    /// view-model uses this to short-circuit the topmost-row `.onAppear`
    /// trigger once we've back-filled the entire room.
    func paginateBackward(requestSize: UInt16) async throws -> Bool

    /// Marks the most recent visible event as read.
    func markAsRead() async throws

    /// Retries a pending/failed own-message (the timeline's tap-to-retry
    /// affordance). `itemID` is the timeline item's id. Implementations
    /// without an offline outbox inherit the default no-op.
    func retrySend(itemID: String) async

    /// Discards an unsent own-message. Default no-op, same as `retrySend`.
    func discardSend(itemID: String) async

    /// Per-convo stream of session-status updates (model, context gauge,
    /// account limits) — journal `status` ephemerals. The journal replays
    /// the last cached status on `viewing`, so subscribing at convo-open
    /// is enough to populate a header immediately.
    func sessionStatus() -> AsyncStream<SessionStatusUpdate>

    /// Per-convo stream of the conversation's session state — "running"
    /// while an agent turn is in flight, "waiting"/"done" otherwise —
    /// mirroring the bridge's durable `session_status` journal events.
    /// Solid for the whole turn, unlike the ephemeral activity indicator
    /// (which the staleness sweep can clear mid-turn); drives the floating
    /// stop button.
    func sessionState() -> AsyncStream<String>

    /// TOC summary entries for this conversation, newest-first. Re-yields on
    /// every change. Default: empty forever (fakes and non-journal backends).
    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]>
}

public extension TimelineService {
    /// Plain send with no reply relation — the shape every pre-Phase-5
    /// call site (composer, slash commands) uses.
    func sendText(_ body: String) async throws {
        try await sendText(body, inReplyTo: nil)
    }

    /// Default: no status source — an immediately-finished stream, so
    /// implementations and test fakes without one need no changes.
    func sessionStatus() -> AsyncStream<SessionStatusUpdate> {
        AsyncStream { $0.finish() }
    }

    /// Default: no session-state source, same immediately-finished shape
    /// as `sessionStatus()`.
    func sessionState() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    /// Default: no summary source, same immediately-finished shape as
    /// `sessionStatus()`/`sessionState()`.
    func summaryEntriesStream() -> AsyncStream<[ConversationSummaryEntry]> {
        AsyncStream { $0.finish() }
    }

    /// Default no-ops so fakes and outbox-less implementations compile
    /// unchanged; `JournalTimelineService` overrides both.
    func retrySend(itemID: String) async {}
    func discardSend(itemID: String) async {}

    /// Defaults: drop the progress handler and forward to the plain sends.
    func sendImage(_ data: Data, filename: String, mimeType: String, caption: String?,
                   progress: (@Sendable (Double) -> Void)?) async throws {
        try await sendImage(data, filename: filename, mimeType: mimeType, caption: caption)
    }

    func sendFile(_ data: Data, filename: String, mimeType: String, caption: String?,
                  progress: (@Sendable (Double) -> Void)?) async throws {
        try await sendFile(data, filename: filename, mimeType: mimeType, caption: caption)
    }
}

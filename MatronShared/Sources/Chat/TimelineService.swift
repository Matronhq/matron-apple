import Foundation
import MatronModels

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

    /// Asks the SDK to paginate older history. UI subscribes via `items()`.
    /// Returns `true` if the SDK has reached the start of the room's
    /// history (further calls would be no-ops); `false` otherwise. The
    /// view-model uses this to short-circuit the topmost-row `.onAppear`
    /// trigger once we've back-filled the entire room.
    func paginateBackward(requestSize: UInt16) async throws -> Bool

    /// Marks the most recent visible event as read.
    func markAsRead() async throws

    /// Per-convo stream of session-status updates (model, context gauge,
    /// account limits) — journal `status` ephemerals. The journal replays
    /// the last cached status on `viewing`, so subscribing at convo-open
    /// is enough to populate a header immediately.
    func sessionStatus() -> AsyncStream<SessionStatusUpdate>
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
}

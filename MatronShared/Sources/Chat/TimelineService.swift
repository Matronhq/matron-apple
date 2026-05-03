import Foundation

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
    func sendText(_ body: String) async throws

    /// Sends an image attachment as an `m.image` event.
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws

    /// Sends a file attachment as an `m.file` event.
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws

    /// Asks the SDK to paginate older history. UI subscribes via `items()`.
    func paginateBackward(requestSize: UInt16) async throws

    /// Marks the most recent visible event as read.
    func markAsRead() async throws
}

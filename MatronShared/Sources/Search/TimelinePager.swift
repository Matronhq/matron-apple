import Foundation

/// A single event surfaced by backward pagination, normalised for indexing.
/// `TimelinePagerLive` produces these from SDK timeline items; `BackfillRunner`
/// consumes them. `indexable` is `true` for text + tool-call results; images,
/// state, redactions, etc. are `false` (still returned so the runner can count
/// pagination depth, but not written to the index).
public struct BackfillItem: Sendable {
    public let eventID: String
    public let sender: String
    public let timestamp: Date
    public let body: String
    /// Text events and tool-call results are indexable. Images, state, redactions are not.
    public let indexable: Bool

    public init(eventID: String, sender: String, timestamp: Date, body: String, indexable: Bool) {
        self.eventID = eventID; self.sender = sender; self.timestamp = timestamp
        self.body = body; self.indexable = indexable
    }
}

/// The seam between `BackfillRunner` and the SDK. Tests pass a fake; production
/// uses `TimelinePagerLive`, which wraps `MatrixRustSDK`. Keeping the runner
/// behind this protocol is what makes the backfill loop fully unit-testable.
public protocol TimelinePager: Sendable {
    /// Paginate one batch backward. Returns the new items revealed and whether
    /// the start of the timeline was reached.
    func paginateBackward(roomID: String, batchSize: Int) async throws -> (items: [BackfillItem], hitStartOfTimeline: Bool)
}

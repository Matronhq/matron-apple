import Foundation

/// Marks one attachment's place in a multi-attachment composer send.
///
/// The composer stamps every attachment of a >1 send with the same `id`
/// (a fresh UUID per send) so the bridge can gather the resulting journal
/// frames back into the single message the user actually wrote, instead
/// of injecting the first image as its own turn and busy-queueing the
/// rest. `index` is 1-based (matching the "2 of 3" upload progress the
/// user watches); `total` is how many frames complete the batch.
///
/// Lives in MatronModels rather than the Journal wire layer because both
/// ends of the seam need it: `TimelineService` (Chat) declares it on the
/// send surface without depending on MatronJournal, and `ClientOp`
/// (Journal) folds it into the media payload as `batch_id` /
/// `batch_index` / `batch_total`.
public struct AttachmentBatchTag: Equatable, Sendable {
    public let id: String
    public let index: Int
    public let total: Int

    public init(id: String, index: Int, total: Int) {
        self.id = id
        self.index = index
        self.total = total
    }
}

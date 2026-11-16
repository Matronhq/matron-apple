import Foundation

/// Where the change-fed streams run their blocking store reads.
///
/// A synchronous `db.read` on a `DatabaseQueue` waits behind any write in
/// progress. Run from a plain `Task`, that wait holds a cooperative-pool
/// thread, and the pool has only as many threads as the device has cores:
/// an open chat and an open item (three feed readers) behind one long
/// catch-up write would take half of a phone's pool. A dispatch queue
/// blocks one of its own threads instead, as GRDB's value observations do,
/// and the awaiting task gives its pool thread back.
enum FeedReads {
    private static let queue = DispatchQueue(label: "chat.matron.feed-reads", qos: .utility,
                                             attributes: .concurrent)

    /// Runs `body` on the feed-read queue and returns its result.
    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

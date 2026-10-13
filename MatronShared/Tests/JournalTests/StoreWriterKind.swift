import Foundation
import XCTest
@testable import MatronJournal

/// The two writers a file-backed `JournalStore` opens on. Suites that run
/// against both declare `class var writerKind` and get a `…PoolTests`
/// subclass that overrides it, so every inherited test runs twice.
enum StoreWriterKind {
    case queue
    case pool

    var usesPool: Bool { self == .pool }
}

extension XCTestCase {
    /// A store on a fresh file in its own temporary directory, removed when
    /// the test ends.
    func makeFileStore(_ kind: StoreWriterKind, ownSender: String = "user:alice",
                       observesSuspension: Bool = JournalStore.observesSuspensionByDefault,
                       metrics: StoreMetrics = .shared,
                       usesChangeFeed: Bool = false) throws -> JournalStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try JournalStore(databaseURL: dir.appendingPathComponent("journal.sqlite"),
                                ownSender: ownSender, observesSuspension: observesSuspension,
                                metrics: metrics, usesChangeFeed: usesChangeFeed,
                                usesPool: kind.usesPool)
    }
}

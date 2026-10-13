import Foundation
import XCTest
@testable import MatronJournal

/// The writers a `JournalStore` opens on: a file-backed queue or pool, or
/// an in-memory queue. Suites that run against several declare
/// `class var writerKind` and get a subclass per extra kind that overrides
/// it, so every inherited test runs once per kind.
enum StoreWriterKind {
    case queue
    case pool
    case memory

    var usesPool: Bool { self == .pool }
}

extension XCTestCase {
    /// A store of `kind`. File-backed kinds get a fresh file in their own
    /// temporary directory, removed when the test ends.
    func makeTestStore(_ kind: StoreWriterKind, ownSender: String = "user:alice",
                       observesSuspension: Bool = JournalStore.observesSuspensionByDefault,
                       metrics: StoreMetrics = .shared,
                       usesChangeFeed: Bool = false) throws -> JournalStore {
        var url: URL?
        if kind != .memory {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            url = dir.appendingPathComponent("journal.sqlite")
        }
        return try JournalStore(databaseURL: url, ownSender: ownSender,
                                observesSuspension: observesSuspension,
                                metrics: metrics, usesChangeFeed: usesChangeFeed,
                                usesPool: kind.usesPool)
    }
}

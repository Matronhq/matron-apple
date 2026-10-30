import GRDB
import XCTest
@testable import MatronJournal

/// Which GRDB writer `JournalStore` opens, and the connection set-up each
/// one gets: `usesPool` picks a `DatabasePool` for a file-backed store, and
/// both kinds run in WAL with `synchronous = NORMAL` on the writer.
final class JournalStoreWriterKindTests: XCTestCase {
    func testAFileBackedStoreOpensAQueueByDefault() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = try JournalStore(databaseURL: dir.appendingPathComponent("journal.sqlite"),
                                     ownSender: "user:alice")
        XCTAssertTrue(store.db is DatabaseQueue)
    }

    func testThePoolFlagOpensAPool() throws {
        XCTAssertTrue(try makeTestStore(.pool).db is DatabasePool)
        XCTAssertTrue(try makeTestStore(.queue).db is DatabaseQueue)
    }

    func testAnInMemoryStoreStaysAQueueWithThePoolFlagOn() throws {
        // A pool needs a file: its readers are separate connections.
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice", usesPool: true)
        XCTAssertTrue(store.db is DatabaseQueue)
    }

    /// Six slow reads at once still leave a reader for the next one. With
    /// GRDB's default of 5 the seventh waited, and so did every write whose
    /// observations needed a reader for their snapshot.
    func testAPoolHasReadersToSpareBeyondSixSlowFetches() throws {
        let store = try makeTestStore(.pool)
        let pool = try XCTUnwrap(store.db as? DatabasePool)
        XCTAssertEqual(pool.configuration.maximumReaderCount, JournalStore.maximumReaderCount)
        let release = DispatchSemaphore(value: 0)
        let holding = DispatchGroup()
        for _ in 0..<6 {
            holding.enter()
            DispatchQueue.global().async {
                try? pool.read { _ in
                    holding.leave()
                    release.wait()
                }
            }
        }
        XCTAssertEqual(holding.wait(timeout: .now() + 5), .success)
        let seventh = expectation(description: "a seventh read runs")
        DispatchQueue.global().async {
            _ = try? pool.read { try Int.fetchOne($0, sql: "SELECT 1") }
            seventh.fulfill()
        }
        wait(for: [seventh], timeout: 2)
        for _ in 0..<6 { release.signal() }
    }

    func testThePoolFlagKeyMatchesTheLaunchArgument() {
        // The rig passes `-store.pool YES`; the apps read this key.
        XCTAssertEqual(JournalStore.poolFlagKey, "store.pool")
    }

    func testAFileBackedQueueStillOpensInWAL() throws {
        // A queue does not turn WAL on by itself; `prepareDatabase` does.
        let store = try makeTestStore(.queue)
        XCTAssertEqual(try store.db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal")
    }

    func testAPoolOpensInWAL() throws {
        let store = try makeTestStore(.pool)
        XCTAssertEqual(try store.db.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal",
                       "seen from a reader")
        XCTAssertEqual(try store.db.write { try String.fetchOne($0, sql: "PRAGMA journal_mode") }, "wal",
                       "seen from the writer")
    }

    func testTheWriterRunsWithSynchronousNormal() throws {
        // 1 is NORMAL. The WAL pairing the store documents in `init`.
        for kind in [StoreWriterKind.queue, .pool] {
            let store = try makeTestStore(kind)
            XCTAssertEqual(try store.db.write { try Int.fetchOne($0, sql: "PRAGMA synchronous") }, 1, "\(kind)")
        }
    }
}

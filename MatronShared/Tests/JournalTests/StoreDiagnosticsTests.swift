import XCTest
@testable import MatronJournal

final class StoreDiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testLastMaintenanceTextIsRelativeAndHandlesNever() {
        XCTAssertEqual(StoreDiagnostics.lastMaintenanceText(nil, now: now), "Never")
        let anHourAgo = StoreDiagnostics.lastMaintenanceText(now.addingTimeInterval(-3600), now: now)
        let aWeekAgo = StoreDiagnostics.lastMaintenanceText(now.addingTimeInterval(-7 * 24 * 3600), now: now)
        XCTAssertNotEqual(anHourAgo, "Never")
        XCTAssertNotEqual(anHourAgo, aWeekAgo, "the row must actually vary with the age it is given")
    }

    func testSizesReadsBothFilesAndBothCounts() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let journalURL = dir.appendingPathComponent("journal.sqlite")
        let searchURL = dir.appendingPathComponent("search.sqlite")

        let store = try JournalStore(databaseURL: journalURL, ownSender: "user:dan")
        for seq in 1...3 {
            try store.applyJournal(JournalEvent(
                seq: Int64(seq), convoID: seq == 3 ? "c2" : "c1",
                ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:dev-2",
                type: JournalEventType.text,
                payloadData: try JSONSerialization.data(withJSONObject: ["body": "hi"])),
                now: Date(timeIntervalSince1970: 10))
        }
        try store.recordMaintenanceRun(at: now)
        try Data(repeating: 7, count: 2048).write(to: searchURL)

        let sizes = await StoreDiagnostics.sizes(store: store, searchURL: searchURL)
        XCTAssertGreaterThan(sizes.journalBytes, 0, "the sqlite file (plus -wal/-shm) has a size")
        XCTAssertEqual(sizes.searchBytes, 2048)
        XCTAssertEqual(sizes.eventCount, 3)
        XCTAssertEqual(sizes.conversationCount, 2)
        XCTAssertEqual(sizes.lastMaintenance, now)
    }

    func testSizesReportsZeroForAnInMemoryStoreAndAMissingIndex() async throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        let sizes = await StoreDiagnostics.sizes(
            store: store,
            searchURL: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/does-not-exist.sqlite"))
        XCTAssertEqual(sizes.journalBytes, 0, "an in-memory store has no file")
        XCTAssertEqual(sizes.searchBytes, 0)
        XCTAssertEqual(sizes.eventCount, 0)
        XCTAssertNil(sizes.lastMaintenance)
    }
}

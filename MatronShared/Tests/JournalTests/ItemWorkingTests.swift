import XCTest
import MatronModels
@testable import MatronJournal

/// An item's `working` state: whether the session that owns it is busy, as
/// the journal reports it on the item.
final class ItemWorkingTests: XCTestCase {
    private func json(working: Any?) -> [String: Any] {
        var json: [String: Any] = ["id": "it_1", "num": 1, "kind": "question", "state": "open", "title": "A question",
                                   "origin_convo_id": "c1", "created_at": 1_000, "updated_at": 2_000]
        if let working { json["working"] = working }
        return json
    }

    func testARunningStateParsesWithItsStart() throws {
        let item = try XCTUnwrap(TrackerItem(json: json(working: ["state": "running", "since": 5_000, "until": NSNull()])))
        XCTAssertEqual(item.working, ItemWorking(state: .running, since: Date(timeIntervalSince1970: 5), until: nil))
    }

    func testAQueuedStateParsesWithWhenItLapses() throws {
        let item = try XCTUnwrap(TrackerItem(json: json(working: ["state": "queued", "since": 5_000, "until": 605_000])))
        XCTAssertEqual(item.working, ItemWorking(state: .queued, since: Date(timeIntervalSince1970: 5),
                                                 until: Date(timeIntervalSince1970: 605)))
    }

    func testNothingToShowIsNil() throws {
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(working: NSNull()))).working)
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(working: nil))).working, "a journal that predates the field")
        XCTAssertNil(try XCTUnwrap(TrackerItem(json: json(working: ["state": "paused"]))).working,
                     "a state this build does not know draws nothing")
    }

    func testAQueuedStateStopsBeingCurrentAtItsDeadline() {
        let until = Date(timeIntervalSince1970: 600)
        let queued = ItemWorking(state: .queued, since: Date(timeIntervalSince1970: 0), until: until)
        XCTAssertTrue(queued.isCurrent(at: until.addingTimeInterval(-1)))
        XCTAssertFalse(queued.isCurrent(at: until))
        XCTAssertTrue(ItemWorking(state: .running).isCurrent(at: .distantFuture), "a running state has no deadline")
    }

    func testTheStoreKeepsTheStateAndClearsItOnTheNextCopy() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        let stamp = Date(timeIntervalSince1970: 2)
        let working = ItemWorking(state: .queued, since: Date(timeIntervalSince1970: 5), until: Date(timeIntervalSince1970: 605))
        func item(_ working: ItemWorking?) -> TrackerItem {
            TrackerItem(id: "it_1", num: 1, kind: .question, title: "A question", originConvoID: "c1",
                        createdAt: Date(timeIntervalSince1970: 1), updatedAt: stamp, working: working)
        }
        try store.upsertItems([item(working)])
        XCTAssertEqual(try store.item(id: "it_1")?.working, working)

        // A turn starting or ending does not bump `updated_at`: the next
        // copy carries the same stamp and must still replace the state.
        try store.upsertItems([item(ItemWorking(state: .running, since: Date(timeIntervalSince1970: 9)))])
        XCTAssertEqual(try store.item(id: "it_1")?.working?.state, .running)
        try store.upsertItems([item(nil)])
        XCTAssertNil(try store.item(id: "it_1")?.working)
    }

    /// A state fetched by an earlier launch says nothing about now.
    func testAStateLeftByAnEarlierLaunchReadsAsNone() throws {
        var record = ItemRecord(TrackerItem(id: "it_1", num: 1, kind: .question, title: "A question", originConvoID: "c1",
                                            working: ItemWorking(state: .running, since: Date(timeIntervalSince1970: 5))))
        XCTAssertEqual(record.item.working?.state, .running)
        let stored = try XCTUnwrap(record.workingJson)
        let launch = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])?["launch"] as? String)
        record.workingJson = stored.replacingOccurrences(of: launch, with: "an-earlier-launch")
        XCTAssertNil(record.item.working)
    }
}

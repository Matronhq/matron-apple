import XCTest
@testable import MatronChat

/// Mirror of the in-memory snapshot machine inside
/// `TimelineSnapshotListener`. Kept as a separate test-only struct so
/// we can drive it without a real SDK `Timeline`. The production code
/// performs *exactly* the same switch in
/// `TimelineSnapshotListener.onUpdate(diff:)`, just over the FFI's
/// `MatrixRustSDK.TimelineDiff` enum instead of `FakeDiff`.
struct SnapshotApplier {
    private(set) var byID: [String: TimelineItem] = [:]
    private(set) var order: [String] = []

    enum FakeDiff {
        case append([TimelineItem])
        case clear
        case pushFront(TimelineItem)
        case pushBack(TimelineItem)
        case popFront
        case popBack
        case insert(Int, TimelineItem)
        case set(Int, TimelineItem)
        case remove(Int)
        case truncate(Int)
        case reset([TimelineItem])
    }

    mutating func apply(_ diffs: [FakeDiff]) {
        for d in diffs {
            switch d {
            case .append(let values):
                for v in values { upsertAtEnd(v) }
            case .clear:
                byID.removeAll()
                order.removeAll()
            case .pushFront(let v):
                insert(v, at: 0)
            case .pushBack(let v):
                upsertAtEnd(v)
            case .popFront:
                guard !order.isEmpty else { break }
                let id = order.removeFirst()
                byID.removeValue(forKey: id)
            case .popBack:
                guard !order.isEmpty else { break }
                let id = order.removeLast()
                byID.removeValue(forKey: id)
            case .insert(let i, let v):
                insert(v, at: i)
            case .set(let i, let v):
                replace(at: i, with: v)
            case .remove(let i):
                removeAt(i)
            case .truncate(let length):
                truncate(to: length)
            case .reset(let values):
                byID.removeAll()
                order.removeAll()
                for v in values { upsertAtEnd(v) }
            }
        }
    }

    var snapshot: [TimelineItem] { order.compactMap { byID[$0] } }

    private mutating func upsertAtEnd(_ item: TimelineItem) {
        if byID[item.id] == nil { order.append(item.id) }
        byID[item.id] = item
    }

    private mutating func insert(_ item: TimelineItem, at index: Int) {
        let clamped = max(0, min(index, order.count))
        if byID[item.id] != nil {
            order.removeAll { $0 == item.id }
        }
        let target = min(clamped, order.count)
        order.insert(item.id, at: target)
        byID[item.id] = item
    }

    private mutating func replace(at index: Int, with item: TimelineItem) {
        guard order.indices.contains(index) else {
            upsertAtEnd(item)
            return
        }
        let oldID = order[index]
        if oldID != item.id {
            byID.removeValue(forKey: oldID)
            order[index] = item.id
        }
        byID[item.id] = item
    }

    private mutating func removeAt(_ index: Int) {
        guard order.indices.contains(index) else { return }
        let id = order.remove(at: index)
        byID.removeValue(forKey: id)
    }

    private mutating func truncate(to length: Int) {
        guard length < order.count else { return }
        let removed = order.suffix(order.count - length)
        order.removeLast(order.count - length)
        for id in removed { byID.removeValue(forKey: id) }
    }
}

private func mkItem(_ id: String, _ body: String = "x") -> TimelineItem {
    TimelineItem(
        id: id,
        sender: "@a:s",
        timestamp: .init(timeIntervalSince1970: 0),
        kind: .text(body: body, formattedHTML: nil),
        isOwn: false
    )
}

final class TimelineDiffApplicationTests: XCTestCase {
    func test_append_addsToEnd() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")])])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_pushFront_addsToHead() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]), .pushFront(mkItem("0"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["0", "1", "2"])
    }

    func test_pushBack_addsToTail() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1")]), .pushBack(mkItem("2"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_popFront_removesHead() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2"), mkItem("3")]), .popFront])
        XCTAssertEqual(a.snapshot.map(\.id), ["2", "3"])
    }

    func test_popFront_onEmpty_isNoOp() {
        var a = SnapshotApplier()
        a.apply([.popFront])
        XCTAssertTrue(a.snapshot.isEmpty)
    }

    func test_popBack_removesTail() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2"), mkItem("3")]), .popBack])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_popBack_onEmpty_isNoOp() {
        var a = SnapshotApplier()
        a.apply([.popBack])
        XCTAssertTrue(a.snapshot.isEmpty)
    }

    func test_insert_atIndex_insertsThere() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("3")]), .insert(1, mkItem("2"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2", "3"])
    }

    func test_insert_atOutOfBoundsIndex_clampsToEnd() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1")]), .insert(99, mkItem("2"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_set_replacesItemAtIndex_inPlace() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1", "old")]), .set(0, mkItem("1", "new"))])
        XCTAssertEqual(a.snapshot.count, 1)
        if case .text(let body, _) = a.snapshot[0].kind {
            XCTAssertEqual(body, "new")
        } else { XCTFail("expected text kind") }
    }

    func test_set_withDifferentID_swapsTheKey() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]), .set(0, mkItem("9"))])
        XCTAssertEqual(a.snapshot.map(\.id), ["9", "2"])
    }

    func test_remove_removesItemAtIndex() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2"), mkItem("3")]), .remove(1)])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "3"])
    }

    func test_truncate_keepsFirstNItems() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2"), mkItem("3"), mkItem("4")]),
                 .truncate(2)])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_truncate_lengthGreaterThanCount_isNoOp() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]), .truncate(99)])
        XCTAssertEqual(a.snapshot.map(\.id), ["1", "2"])
    }

    func test_reset_replacesEverything() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1"), mkItem("2")]),
                 .reset([mkItem("9"), mkItem("10")])])
        XCTAssertEqual(a.snapshot.map(\.id), ["9", "10"])
    }

    func test_clear_emptiesSnapshot() {
        var a = SnapshotApplier()
        a.apply([.append([mkItem("1")]), .clear])
        XCTAssertTrue(a.snapshot.isEmpty)
    }

    func test_unknownEventType_isPreservedNotDropped() {
        var a = SnapshotApplier()
        let unk = TimelineItem(
            id: "u1",
            sender: "@a:s",
            timestamp: .init(timeIntervalSince1970: 0),
            kind: .unknown(eventType: "m.room.encryption"),
            isOwn: false
        )
        a.apply([.append([unk])])
        XCTAssertEqual(a.snapshot.count, 1)
        if case .unknown(let t) = a.snapshot[0].kind {
            XCTAssertEqual(t, "m.room.encryption")
        } else { XCTFail("expected unknown kind") }
    }

    func test_localEcho_replacedByRemote_preservesPosition() {
        // Simulates the local-echo → remote-event transition: the SDK
        // sets the same index with a new id (event id replaces tx id).
        var a = SnapshotApplier()
        a.apply([
            .append([mkItem("tx:abc", "hello"), mkItem("evt:1", "later")]),
            .set(0, mkItem("evt:0", "hello")),
        ])
        XCTAssertEqual(a.snapshot.map(\.id), ["evt:0", "evt:1"])
    }

    func test_insert_existingID_movesItToNewPosition() {
        // Defensive: inserting an item whose id already exists moves
        // the existing entry to the new position rather than
        // duplicating it.
        var a = SnapshotApplier()
        a.apply([
            .append([mkItem("1"), mkItem("2"), mkItem("3")]),
            .insert(0, mkItem("3", "moved")),
        ])
        XCTAssertEqual(a.snapshot.map(\.id), ["3", "1", "2"])
    }
}

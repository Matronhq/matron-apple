import XCTest
@testable import MatronChat

/// Diff-application unit tests for `RoomListEntriesAlgorithm.apply` —
/// the pure ordered-list mutation extracted from `RoomListSubscription`
/// so we can exercise every `RoomListEntriesUpdate` variant without
/// spinning up a real homeserver. Each test feeds a synthetic batch
/// through the algorithm and asserts the resulting room ID order.
///
/// Why a fake `RoomLike`: `MatrixRustSDK.Room` is `open class
/// @unchecked Sendable` with FFI-bound storage; not directly fakeable
/// in unit tests. The algorithm only reads `id()` off `RoomLike`, so a
/// trivial reference-typed fake is enough to cover every variant.
final class RoomListSubscriptionTests: XCTestCase {

    // MARK: - Append

    func test_append_addsValuesInOrder() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply(
            [.append([.id("b"), .id("c")])],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b", "c"])
        XCTAssertEqual(result.touched, [1, 2])
        XCTAssertFalse(result.resetAll)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - PushBack

    func test_pushBack_appendsOne() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply([.pushBack(.id("b"))], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b"])
        XCTAssertEqual(result.touched, [1])
    }

    // MARK: - PushFront

    func test_pushFront_prependsOne_andTouchesEverything() {
        var rooms: [FakeRoom] = [.id("a"), .id("b")]
        let result = RoomListEntriesAlgorithm.apply([.pushFront(.id("z"))], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["z", "a", "b"])
        // resetAll because every existing index shifted; caller widens
        // the touched set to the full range so cached summaries stay
        // consistent (they're keyed by ID, but recompute is idempotent).
        XCTAssertTrue(result.resetAll)
        XCTAssertEqual(result.touched, [0, 1, 2])
    }

    // MARK: - PopBack

    func test_popBack_removesLast_andRecordsDropped() {
        var rooms: [FakeRoom] = [.id("a"), .id("b")]
        let result = RoomListEntriesAlgorithm.apply([.popBack], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a"])
        XCTAssertEqual(result.dropped, ["b"])
    }

    func test_popBack_emptyList_isNoOp() {
        var rooms: [FakeRoom] = []
        let result = RoomListEntriesAlgorithm.apply([.popBack], to: &rooms)
        XCTAssertTrue(rooms.isEmpty)
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - PopFront

    func test_popFront_removesFirst_andTouchesEverything() {
        var rooms: [FakeRoom] = [.id("a"), .id("b"), .id("c")]
        let result = RoomListEntriesAlgorithm.apply([.popFront], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["b", "c"])
        XCTAssertEqual(result.dropped, ["a"])
        XCTAssertTrue(result.resetAll)
    }

    // MARK: - Insert

    func test_insert_atMiddle_shiftsTail_andTouchesEverything() {
        var rooms: [FakeRoom] = [.id("a"), .id("c")]
        let result = RoomListEntriesAlgorithm.apply(
            [.insert(index: 1, value: .id("b"))],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b", "c"])
        XCTAssertTrue(result.resetAll)
    }

    func test_insert_atEnd_isAppend() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply(
            [.insert(index: 1, value: .id("b"))],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b"])
        XCTAssertTrue(result.resetAll)
    }

    func test_insert_outOfBounds_isNoOp() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply(
            [.insert(index: 99, value: .id("b"))],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a"])
        XCTAssertFalse(result.resetAll)
    }

    // MARK: - Remove

    func test_remove_removesAtIndex_andRecordsDropped() {
        var rooms: [FakeRoom] = [.id("a"), .id("b"), .id("c")]
        let result = RoomListEntriesAlgorithm.apply([.remove(index: 1)], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "c"])
        XCTAssertEqual(result.dropped, ["b"])
        // Cached summaries for "c" remain valid (keyed by ID), so we do
        // NOT widen touched. Only the row's position shifted.
        XCTAssertFalse(result.resetAll)
    }

    func test_remove_outOfBounds_isNoOp() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply([.remove(index: 5)], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a"])
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Set

    func test_set_replacesAtIndex_andDropsOldID() {
        var rooms: [FakeRoom] = [.id("a"), .id("b"), .id("c")]
        let result = RoomListEntriesAlgorithm.apply(
            [.set(index: 1, value: .id("B"))],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "B", "c"])
        XCTAssertEqual(result.dropped, ["b"])
        XCTAssertEqual(result.touched, [1])
    }

    func test_set_sameID_doesNotDrop() {
        // .set with a Room that has the same ID happens when the SDK
        // replaces the underlying handle for the same room — e.g. after
        // a state refresh. The cached summary for that ID is still
        // referencing the same room, so dropping it would force an
        // unnecessary recompute. The algorithm leaves it; only `touched`
        // signals the recompute.
        let original = FakeRoom.id("b")
        var rooms: [FakeRoom] = [.id("a"), original]
        let replacement = FakeRoom.id("b")
        let result = RoomListEntriesAlgorithm.apply(
            [.set(index: 1, value: replacement)],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b"])
        XCTAssertTrue(result.dropped.isEmpty)
        XCTAssertEqual(result.touched, [1])
    }

    // MARK: - Truncate

    func test_truncate_dropsTail_andRecordsAllDropped() {
        var rooms: [FakeRoom] = [.id("a"), .id("b"), .id("c"), .id("d")]
        let result = RoomListEntriesAlgorithm.apply([.truncate(length: 2)], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b"])
        XCTAssertEqual(result.dropped, ["c", "d"])
    }

    func test_truncate_lengthMatchesCount_isNoOp() {
        var rooms: [FakeRoom] = [.id("a"), .id("b")]
        let result = RoomListEntriesAlgorithm.apply([.truncate(length: 2)], to: &rooms)
        XCTAssertEqual(rooms.map { $0.id() }, ["a", "b"])
        XCTAssertTrue(result.dropped.isEmpty)
    }

    // MARK: - Clear

    func test_clear_emptiesList_andDropsEverything() {
        var rooms: [FakeRoom] = [.id("a"), .id("b")]
        let result = RoomListEntriesAlgorithm.apply([.clear], to: &rooms)
        XCTAssertTrue(rooms.isEmpty)
        XCTAssertEqual(result.dropped, ["a", "b"])
    }

    // MARK: - Reset

    func test_reset_replacesEntireList_andTouchesEverything() {
        var rooms: [FakeRoom] = [.id("a"), .id("b")]
        let result = RoomListEntriesAlgorithm.apply(
            [.reset([.id("x"), .id("y"), .id("z")])],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["x", "y", "z"])
        XCTAssertEqual(result.dropped, ["a", "b"])
        XCTAssertTrue(result.resetAll)
        XCTAssertEqual(result.touched, [0, 1, 2])
    }

    func test_reset_toEmpty_clearsList() {
        var rooms: [FakeRoom] = [.id("a")]
        let result = RoomListEntriesAlgorithm.apply([.reset([])], to: &rooms)
        XCTAssertTrue(rooms.isEmpty)
        XCTAssertEqual(result.dropped, ["a"])
        XCTAssertTrue(result.resetAll)
    }

    // MARK: - Batched diffs

    func test_batch_appliesEachDiffInOrder() {
        // Mirrors a realistic listener fire: an initial reset followed
        // by a pushBack for a freshly-created room, all in one batch.
        var rooms: [FakeRoom] = []
        let result = RoomListEntriesAlgorithm.apply(
            [
                .reset([.id("a"), .id("b")]),
                .pushBack(.id("c")),
                .set(index: 0, value: .id("A")),
            ],
            to: &rooms
        )
        XCTAssertEqual(rooms.map { $0.id() }, ["A", "b", "c"])
        // resetAll wins from .reset; .set's dropped IDs are also recorded.
        XCTAssertTrue(result.resetAll)
        XCTAssertEqual(Set(result.dropped), Set(["a"]))
    }
}

/// Reference-typed fake satisfying `RoomLike`. `id()` is the only method
/// the diff algorithm reads off `RoomLike`; everything else stays out
/// of test scope. Kept fileprivate to the test target so it can't leak
/// into production code paths.
private final class FakeRoom: RoomLike, @unchecked Sendable {
    private let _id: String
    init(_ id: String) { self._id = id }
    func id() -> String { _id }

    static func id(_ id: String) -> FakeRoom { FakeRoom(id) }
}

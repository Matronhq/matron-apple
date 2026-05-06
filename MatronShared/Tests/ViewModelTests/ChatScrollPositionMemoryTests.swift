import XCTest
@testable import MatronViewModels

/// Pins the per-room scroll-position cache contract used by `ChatView` /
/// `MacChatView` (`.task` restore + `.onDisappear` store, `forget` on
/// jump-to-bottom). Mirrors `ComposerDraftMemoryTests` — same shape, same
/// invariants, different surface.
final class ChatScrollPositionMemoryTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        ChatScrollPositionMemory._resetForTesting()
    }

    @MainActor
    func test_retrieve_returnsNil_whenNothingStored() {
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!unknown:s"))
    }

    @MainActor
    func test_store_thenRetrieve_returnsExactValue() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1")
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!a:s"), "$ev1")
    }

    @MainActor
    func test_store_nil_clearsEntry() {
        // Falling-back-to-tail behaviour relies on `store(roomID:itemID: nil)`
        // dropping the entry — `ChatView.onDisappear` uses this when the
        // user is sitting at the live tail (no point storing "user was at
        // the latest message").
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1")
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: nil)
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!a:s"))
    }

    @MainActor
    func test_forget_dropsSingleRoom() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev1")
        ChatScrollPositionMemory.store(roomID: "!b:s", itemID: "$ev2")
        ChatScrollPositionMemory.forget(roomID: "!a:s")
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!a:s"))
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!b:s"), "$ev2",
                       "forget must not touch unrelated rooms")
    }

    @MainActor
    func test_positions_areIsolatedPerRoom() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$ev-a")
        ChatScrollPositionMemory.store(roomID: "!b:s", itemID: "$ev-b")
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!a:s"), "$ev-a")
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!b:s"), "$ev-b")
    }

    @MainActor
    func test_store_overwritesPriorValue() {
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$first")
        ChatScrollPositionMemory.store(roomID: "!a:s", itemID: "$second")
        XCTAssertEqual(ChatScrollPositionMemory.retrieve(roomID: "!a:s"), "$second")
    }

    @MainActor
    func test_forget_isIdempotent_whenRoomAbsent() {
        // Jump-to-bottom calls `forget` unconditionally; absence must
        // not throw / trap.
        ChatScrollPositionMemory.forget(roomID: "!unknown:s")
        XCTAssertNil(ChatScrollPositionMemory.retrieve(roomID: "!unknown:s"))
    }
}

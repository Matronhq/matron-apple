import XCTest
@testable import MatronViewModels

/// Pins the per-room composer-draft cache contract used by
/// `ComposerView` / `MacComposerView` (`.task` restore + `.onDisappear`
/// store) and by `ComposerViewModel.send()` (`forget` on success).
/// Mirrors the `ChatScrollPositionMemory` test shape: store, retrieve,
/// forget, multi-room isolation.
final class ComposerDraftMemoryTests: XCTestCase {
    @MainActor
    override func setUp() {
        super.setUp()
        ComposerDraftMemory._resetForTesting()
    }

    @MainActor
    func test_retrieve_returnsNil_whenNothingStored() {
        XCTAssertNil(ComposerDraftMemory.retrieve(roomID: "!unknown:s"))
    }

    @MainActor
    func test_store_thenRetrieve_returnsExactValue() {
        ComposerDraftMemory.store(roomID: "!a:s", text: "half-typed message")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!a:s"), "half-typed message")
    }

    @MainActor
    func test_store_preservesTrailingWhitespace() {
        // Trailing-space preservation is load-bearing: `selectCommand`
        // sets input to "/start " (note the trailing space) so the
        // palette closes and the caret is positioned for arguments. A
        // trim on store would collapse this back and re-open the
        // palette on the next visit.
        ComposerDraftMemory.store(roomID: "!a:s", text: "/start ")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!a:s"), "/start ")
    }

    @MainActor
    func test_store_emptyString_clearsEntry() {
        ComposerDraftMemory.store(roomID: "!a:s", text: "draft")
        ComposerDraftMemory.store(roomID: "!a:s", text: "")
        XCTAssertNil(ComposerDraftMemory.retrieve(roomID: "!a:s"),
                     "storing empty must clear so a sent composer doesn't ghost text into the next visit")
    }

    @MainActor
    func test_forget_dropsSingleRoom() {
        ComposerDraftMemory.store(roomID: "!a:s", text: "draft A")
        ComposerDraftMemory.store(roomID: "!b:s", text: "draft B")
        ComposerDraftMemory.forget(roomID: "!a:s")
        XCTAssertNil(ComposerDraftMemory.retrieve(roomID: "!a:s"))
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!b:s"), "draft B",
                       "forget must not touch unrelated rooms")
    }

    @MainActor
    func test_drafts_areIsolatedPerRoom() {
        ComposerDraftMemory.store(roomID: "!a:s", text: "AAA")
        ComposerDraftMemory.store(roomID: "!b:s", text: "BBB")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!a:s"), "AAA")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!b:s"), "BBB")
    }

    @MainActor
    func test_store_overwritesPriorValue() {
        ComposerDraftMemory.store(roomID: "!a:s", text: "first")
        ComposerDraftMemory.store(roomID: "!a:s", text: "second")
        XCTAssertEqual(ComposerDraftMemory.retrieve(roomID: "!a:s"), "second")
    }
}

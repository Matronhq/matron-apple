import XCTest
import MatronModels

/// Pins `ItemReadMemory`'s contract: `ItemDetailHost`/`MacItemDetailHost`
/// read `wasAtBottom(itemID:)` once to decide whether a re-opened item
/// should land at the tail of its comment thread, and store the reader's
/// latest bottom-visibility on item-id change / disappear (see
/// `ItemDetailView`'s `onBottomVisibilityChange`).
///
/// Uses a private `UserDefaults(suiteName:)`, never `.standard` — sharing
/// the real defaults would leak state between test runs and into the
/// developer's own app data.
final class ItemReadMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "ItemReadMemoryTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func test_wasAtBottom_returnsFalse_whenNothingStored() {
        let memory = ItemReadMemory(defaults: defaults)
        XCTAssertFalse(memory.wasAtBottom(itemID: "it_1"))
    }

    func test_store_thenWasAtBottom_returnsExactValue() {
        let memory = ItemReadMemory(defaults: defaults)
        memory.store(itemID: "it_1", atBottom: true)
        XCTAssertTrue(memory.wasAtBottom(itemID: "it_1"))
    }

    func test_store_false_overwritesPriorTrue() {
        let memory = ItemReadMemory(defaults: defaults)
        memory.store(itemID: "it_1", atBottom: true)
        memory.store(itemID: "it_1", atBottom: false)
        XCTAssertFalse(memory.wasAtBottom(itemID: "it_1"))
    }

    func test_positions_areIsolatedPerItem() {
        let memory = ItemReadMemory(defaults: defaults)
        memory.store(itemID: "it_1", atBottom: true)
        memory.store(itemID: "it_2", atBottom: false)
        XCTAssertTrue(memory.wasAtBottom(itemID: "it_1"))
        XCTAssertFalse(memory.wasAtBottom(itemID: "it_2"))
    }

    func test_forget_dropsSingleItem_andFallsBackToFalse() {
        let memory = ItemReadMemory(defaults: defaults)
        memory.store(itemID: "it_1", atBottom: true)
        memory.forget(itemID: "it_1")
        XCTAssertFalse(memory.wasAtBottom(itemID: "it_1"))
    }

    func test_forget_doesNotTouchOtherItems() {
        let memory = ItemReadMemory(defaults: defaults)
        memory.store(itemID: "it_1", atBottom: true)
        memory.store(itemID: "it_2", atBottom: true)
        memory.forget(itemID: "it_1")
        XCTAssertTrue(memory.wasAtBottom(itemID: "it_2"))
    }

    func test_separateInstances_shareTheSameBackingDefaults() {
        // `ItemDetailHost`/`MacItemDetailHost` each construct their own
        // `ItemReadMemory()` rather than sharing one instance — this pins
        // that two instances over the same `UserDefaults` see each
        // other's writes (unlike `ChatScrollPositionMemory`'s in-memory
        // dictionary, which is process-lifetime and instance-agnostic by
        // construction).
        ItemReadMemory(defaults: defaults).store(itemID: "it_1", atBottom: true)
        XCTAssertTrue(ItemReadMemory(defaults: defaults).wasAtBottom(itemID: "it_1"))
    }
}

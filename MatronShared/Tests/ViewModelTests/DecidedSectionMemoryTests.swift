import XCTest
import MatronModels

/// Pins `DecidedSectionMemory`'s contract — the Decisions view's "Decided"
/// section reads `load()` once to seed `ItemsPanelViewModel.isDecidedExpanded`
/// and calls `store(_:)` every time the user toggles it, so the section
/// stays expanded/collapsed exactly as they left it across a relaunch.
///
/// Uses a private `UserDefaults(suiteName:)`, never `.standard` — mirrors
/// `ItemReadMemoryTests`' own discipline.
final class DecidedSectionMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "DecidedSectionMemoryTests"

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

    func test_load_returnsFalse_whenNothingStored() {
        XCTAssertFalse(DecidedSectionMemory(defaults: defaults).load())
    }

    func test_store_thenLoad_returnsExactValue() {
        let memory = DecidedSectionMemory(defaults: defaults)
        memory.store(true)
        XCTAssertTrue(memory.load())
        memory.store(false)
        XCTAssertFalse(memory.load())
    }

    func test_separateInstances_shareTheSameBackingDefaults() {
        DecidedSectionMemory(defaults: defaults).store(true)
        XCTAssertTrue(DecidedSectionMemory(defaults: defaults).load())
    }
}

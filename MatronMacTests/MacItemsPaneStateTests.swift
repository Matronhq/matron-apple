#if os(macOS)
import XCTest
@testable import MatronMac
import MatronModels
import MatronJournal
import MatronViewModels

/// Slot lifetime for the Mac items pane. Item links made the pane a real
/// two-level stack (#115): pushing #12 over #9 used to overwrite the one
/// detail slot, so Back rebuilt #9's `ItemDetailViewModel` from scratch and
/// silently dropped the half-typed comment in its `draft` — the only place
/// that text lives. One slot per item on the stack is the fix; these pin
/// both halves of it (keep while reachable, release when not).
private final class NoopItemsStore: ItemsStoreReading, @unchecked Sendable {
    func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
    func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { _ in } }
    func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
    func comments(itemID: String) throws -> [TrackerComment] { [] }
    func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
}

private final class NoopItemsSync: ItemsSyncing, @unchecked Sendable {
    func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
    func refreshItem(id: String) async {}
    func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async {}
    func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
}

private final class NoopItemsAPI: ItemsProviding, @unchecked Sendable {
    func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { ItemsPage(items: [], nextCursor: nil) }
    func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { throw JournalAPIError.notFound }
    func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func commentItem(id: String, body: String, attachments: [TrackerAttachment], idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { throw JournalAPIError.notFound }
    func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func reopenItem(id: String, comment: String?) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { throw JournalAPIError.notFound }
    func uploadMedia(_ data: Data, contentType: String) async throws -> String { "b" }
}

@MainActor
final class MacItemsPaneStateTests: XCTestCase {

    /// A scratch defaults suite — releasing a slot persists its read
    /// position, and a test must not write that into the real domain.
    private var defaults: UserDefaults!
    private let suiteName = "MacItemsPaneStateTests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeState() -> MacItemsPaneState {
        MacItemsPaneState(readMemory: ItemReadMemory(defaults: defaults))
    }

    private func makeViewModel(_ itemID: String) -> ItemDetailViewModel {
        ItemDetailViewModel(itemID: itemID, store: NoopItemsStore(), api: NoopItemsAPI(), sync: NoopItemsSync())
    }

    /// Push #12 over #9, then Back: #9's slot — and the view model holding
    /// its draft — is the SAME object, so nothing has to be rebuilt.
    func test_popBackToAnItemStillOnTheStackKeepsItsViewModelAndDraft() {
        let state = makeState()

        // Open item A (list → detail).
        state.path = ["A"]
        let slotA = state.slot(for: "A")
        let vmA = makeViewModel("A")
        slotA.viewModel = vmA
        vmA.draft = "half-typed reply"

        // Tap an item link in A's body: B pushes OVER A.
        state.path = ["A", "B"]
        state.releaseSlots(keeping: Set(state.path))
        let slotB = state.slot(for: "B")
        slotB.viewModel = makeViewModel("B")
        XCTAssertTrue(state.slot(for: "A") === slotA, "A is still on the stack — its slot must survive the push")

        // Back.
        state.path = ["A"]
        state.releaseSlots(keeping: Set(state.path))
        XCTAssertTrue(state.slot(for: "A") === slotA)
        XCTAssertTrue(state.slot(for: "A").viewModel === vmA, "Back must find A's existing view model, not a rebuilt one")
        XCTAssertEqual(state.slot(for: "A").viewModel?.draft, "half-typed reply")
    }

    /// …and the item that was popped OFF is released: its view model is
    /// stopped and the slot is gone (no per-tap leak of running streams).
    func test_slotIsReleasedWhenItsItemLeavesThePath() {
        let state = makeState()
        state.path = ["A", "B"]
        let slotB = state.slot(for: "B")
        slotB.viewModel = makeViewModel("B")
        slotB.isAtBottom = true
        XCTAssertEqual(Set(state.slots.keys), ["B"])

        state.path = ["A"]
        state.releaseSlots(keeping: Set(state.path))

        XCTAssertNil(state.slots["B"], "a popped item's slot is released")
        // Released slots persist their read position on the way out — the
        // job the old single-slot swap did inline.
        XCTAssertTrue(ItemReadMemory(defaults: defaults).wasAtBottom(itemID: "B"))
    }

    /// Popping all the way back to the list frees everything, and so does
    /// a surface teardown.
    func test_releaseAllSlotsClearsTheWholeSurface() {
        let state = makeState()
        state.path = ["A", "B"]
        state.slot(for: "A").viewModel = makeViewModel("A")
        state.slot(for: "B").viewModel = makeViewModel("B")

        state.releaseSlots(keeping: [])
        XCTAssertTrue(state.slots.isEmpty)

        state.slot(for: "C").viewModel = makeViewModel("C")
        state.releaseAllSlots()
        XCTAssertTrue(state.slots.isEmpty)
    }

    /// Popping the pane back to its LIST must not resurrect the host that
    /// was just popped (Bugbot, #115 round 4). Its `.task` is keyed on the
    /// top of the stack, so it re-fires with an empty path — which used to
    /// read as "the stackless Decisions surface, this host is on screen",
    /// so the host rebuilt its slot and started a fresh view model (store
    /// streams and a `refreshItem`) behind the list.
    func test_activationAfterPoppingToTheListBuildsNothing() {
        let state = makeState()

        // List → A.
        state.path = ["A"]
        let slotA = state.activateSlot(for: "A", surface: .stack)
        XCTAssertNotNil(slotA, "the item on top of the stack activates")
        slotA?.viewModel = makeViewModel("A")

        // Back to the list. The pane's `onChange(of: path)` is the single
        // owner of release.
        state.path = []
        state.releaseSlots(keeping: Set(state.path))
        XCTAssertTrue(state.slots.isEmpty)

        // A's host is popped but its task re-fires with the new (empty) path.
        XCTAssertNil(state.activateSlot(for: "A", surface: .stack),
                     "a host that is no longer on the path must never activate")
        XCTAssertTrue(state.slots.isEmpty, "…and must not recreate the slot it was just released from")
        XCTAssertNil(state.slots["A"]?.viewModel)
    }

    /// A host buried UNDER a push is equally off screen — the same guard,
    /// and the stackless surface is unaffected by either.
    func test_activationIsForTheItemOnTopOnlyAndStacklessAlwaysActivates() {
        let state = makeState()
        state.path = ["A", "B"]
        XCTAssertNil(state.activateSlot(for: "A", surface: .stack), "A is buried under B")
        XCTAssertNotNil(state.activateSlot(for: "B", surface: .stack))

        // Decisions: no path at all, and the one visible host still runs.
        let stackless = makeState()
        XCTAssertTrue(stackless.path.isEmpty)
        XCTAssertNotNil(stackless.activateSlot(for: "A", surface: .stackless))
        // …owning its own release, since it has no path to observe.
        XCTAssertNotNil(stackless.activateSlot(for: "B", surface: .stackless))
        XCTAssertEqual(Set(stackless.slots.keys), ["B"])
    }

    /// The stackless Decisions surface (empty `path`) keeps exactly one
    /// slot: selecting another item releases the previous one, which is
    /// what the single-slot design used to do by overwriting.
    func test_stacklessSurfaceKeepsOnlyTheSelectedItem() {
        let state = makeState()
        state.slot(for: "A").viewModel = makeViewModel("A")
        state.releaseSlots(keeping: ["B"])
        state.slot(for: "B").viewModel = makeViewModel("B")

        XCTAssertEqual(Set(state.slots.keys), ["B"])
    }
}
#endif

import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

/// The item detail's context block: the item's mission and the
/// conversation that owns it — always, even when this device has no row for
/// it.
@MainActor
final class ItemDetailContextTests: XCTestCase {
    // MARK: - ItemContext.make

    private static func item(origin: String = "c-origin", missionID: String? = "m1", missionNum: Int? = 61,
                             originTitle: String? = nil) -> TrackerItem {
        TrackerItem(id: "it_1", num: 10_563, kind: .task, title: "Ship it", originConvoID: origin,
                    missionID: missionID, missionNum: missionNum, originConvoTitle: originTitle)
    }

    private static let mission = Mission(id: "m1", num: 61, title: "Launch the promo site", originConvoID: "c-origin")

    func testTheMissionRowNamesTheMissionByNameThenTitle() {
        let byTitle = ItemContext.make(item: Self.item(), currentConvoID: nil, mission: Self.mission,
                                       ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(byTitle.mission, .init(num: 61, label: "#61 Launch the promo site"))
        let named = Mission(id: "m1", num: 61, title: "Launch the promo site", originConvoID: "c-origin", name: "Promo")
        let byName = ItemContext.make(item: Self.item(), currentConvoID: nil, mission: named,
                                      ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(byName.mission?.label, "#61 Promo")
    }

    func testAMissionThisDeviceDoesNotHaveIsNamedByNumber() {
        let context = ItemContext.make(item: Self.item(), currentConvoID: nil, mission: nil,
                                       ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(context.mission, .init(num: 61, label: "Mission #61"))
    }

    func testAnItemWithNoMissionHasOnlyTheOwnerRow() {
        let context = ItemContext.make(item: Self.item(missionID: nil, missionNum: nil), currentConvoID: nil, mission: nil,
                                       ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(context, ItemContext(owner: .init(id: "c-origin", label: "Conversation")))
    }

    func testTheOwnerRowIsAlwaysThereFallingBackToTheJournalTitleThenAGenericLabel() {
        let local = ItemContext.make(item: Self.item(originTitle: "[ab] Server"), currentConvoID: nil, mission: nil,
                                     ownerLabel: "dev-mac · [ab] Server", ownerIsOpenable: true)
        XCTAssertEqual(local.owner, .init(id: "c-origin", label: "dev-mac · [ab] Server"))
        let server = ItemContext.make(item: Self.item(originTitle: "[ab] Server"), currentConvoID: nil, mission: nil,
                                      ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(server.owner, .init(id: "c-origin", label: "[ab] Server"))
        let unnamed = ItemContext.make(item: Self.item(), currentConvoID: nil, mission: nil,
                                       ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(unnamed.owner, .init(id: "c-origin", label: "Conversation"))
    }

    func testInsideItsOwnConversationTheOwnerRowHidesButTheMissionRowStays() {
        let context = ItemContext.make(item: Self.item(), currentConvoID: "c-origin", mission: Self.mission,
                                       ownerLabel: "dev-mac · [ab] Server", ownerIsOpenable: true)
        XCTAssertEqual(context.mission?.num, 61)
        XCTAssertNil(context.owner)
    }

    func testInsideAnotherConversationTheOwnerRowShows() {
        let context = ItemContext.make(item: Self.item(), currentConvoID: "c-elsewhere", mission: nil,
                                       ownerLabel: nil, ownerIsOpenable: true)
        XCTAssertEqual(context.owner?.id, "c-origin")
    }

    func testAGrantedItemHasNoOwnerRow() {
        let context = ItemContext.make(item: Self.item(origin: ""), currentConvoID: nil, mission: Self.mission,
                                       ownerLabel: nil, ownerIsOpenable: false)
        XCTAssertNil(context.owner)
        XCTAssertEqual(context.mission?.num, 61)
        XCTAssertTrue(ItemContext.make(item: Self.item(origin: "", missionID: nil, missionNum: nil), currentConvoID: nil,
                                       mission: nil, ownerLabel: nil, ownerIsOpenable: false).isEmpty)
    }

    func testAnOwnerThisDeviceHasNoRowForIsNamedButNotOpenable() {
        let context = ItemContext.make(item: Self.item(originTitle: "[ab] Server"), currentConvoID: nil, mission: Self.mission,
                                       ownerLabel: nil, ownerIsOpenable: false)
        XCTAssertEqual(context.owner, .init(id: "c-origin", label: "[ab] Server", isOpenable: false))
    }

    // MARK: - ItemDetailViewModel

    func testTheViewModelFollowsTheMissionAndLabelsTheOwner() async throws {
        let store = Store(); let contextStore = ContextStore(); let fetched = Fetched()
        contextStore.labels = ["c-origin": "dev-mac · [ab] Server"]
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(),
                                     contextStore: contextStore, refreshMission: { id in fetched.add(id) })
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.item != nil && contextStore.missionCont != nil && fetched.all == ["m1"] }
        XCTAssertEqual(vm.context(currentConvoID: nil),
                       ItemContext(mission: .init(num: 61, label: "Mission #61"),
                                   owner: .init(id: "c-origin", label: "dev-mac · [ab] Server")),
                       "named by number until the mission lands")
        XCTAssertEqual(fetched.all, ["m1"], "one detail fetch for a mission this device lacks")

        contextStore.missionCont?.yield(Self.mission)
        try await waitUntil { vm.context(currentConvoID: nil).mission?.label == "#61 Launch the promo site" }

        // An item update that keeps the mission costs no second fetch, even
        // if the mission row goes missing again.
        contextStore.missionCont?.yield(nil)
        store.itemCont?.yield(Self.item(originTitle: "renamed"))
        try await waitUntil { vm.item?.originConvoTitle == "renamed" && vm.context(currentConvoID: nil).mission?.label == "Mission #61" }
        XCTAssertEqual(fetched.all, ["m1"])
        XCTAssertEqual(vm.context(currentConvoID: "c-origin").owner, nil, "hidden inside its own conversation")
        vm.stop()
    }

    func testAMissionAlreadyOnThisDeviceIsNotFetched() async throws {
        let store = Store(); let contextStore = ContextStore(); let fetched = Fetched()
        contextStore.initialMission = Self.mission
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(),
                                     contextStore: contextStore, refreshMission: { id in fetched.add(id) })
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item())
        try await waitUntil { vm.context(currentConvoID: nil).mission?.label == "#61 Launch the promo site" }
        // The fetch decision is made in the same stream step that sets the
        // mission, and the stream never yielded `nil`, so no fetch exists.
        XCTAssertEqual(fetched.all, [])
        vm.stop()
    }

    /// The owner conversation syncs to this device after the item opened:
    /// the row takes the local label and becomes a link without a restart.
    func testAnOwnerThatSyncsLaterBecomesOpenable() async throws {
        let store = Store(); let contextStore = ContextStore()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(), contextStore: contextStore)
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(missionID: nil, missionNum: nil, originTitle: "[ab] Server"))
        try await waitUntil { vm.item != nil && contextStore.ownerCont != nil }
        XCTAssertEqual(vm.context(currentConvoID: nil).owner, .init(id: "c-origin", label: "[ab] Server", isOpenable: false))
        contextStore.ownerCont?.yield(.init(exists: true, label: "dev-mac · [ab] Server"))
        try await waitUntil { vm.context(currentConvoID: nil).owner?.isOpenable == true }
        XCTAssertEqual(vm.context(currentConvoID: nil).owner, .init(id: "c-origin", label: "dev-mac · [ab] Server"))
        vm.stop()
    }

    func testWithoutAMissionNothingIsFetched() async throws {
        let store = Store(); let contextStore = ContextStore(); let fetched = Fetched()
        let vm = ItemDetailViewModel(itemID: "it_1", store: store, api: API(), sync: Sync(),
                                     contextStore: contextStore, refreshMission: { id in fetched.add(id) })
        vm.start()
        try await waitUntil { store.itemCont != nil }
        store.itemCont?.yield(Self.item(missionID: nil, missionNum: nil, originTitle: "[ab] Server"))
        try await waitUntil { vm.item != nil }
        XCTAssertEqual(vm.context(currentConvoID: nil),
                       ItemContext(owner: .init(id: "c-origin", label: "[ab] Server", isOpenable: false)),
                       "named from the journal's title; no row here, so nothing to open")
        XCTAssertNil(contextStore.missionCont)
        XCTAssertEqual(fetched.all, [])
        vm.stop()
    }

    // MARK: - Fakes

    private final class Fetched: @unchecked Sendable {
        private let lock = NSLock(); private var ids: [String] = []
        func add(_ id: String) { lock.lock(); ids.append(id); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return ids }
    }
    private final class ContextStore: ItemContextReading, @unchecked Sendable {
        /// Conversations this device has, by id, with their labels.
        var labels: [String: String] = [:]
        /// What the mission stream yields first: `nil` is "not on this
        /// device".
        var initialMission: Mission?
        var missionCont: AsyncStream<Mission?>.Continuation?
        var ownerCont: AsyncStream<JournalStore.ConversationOrigin>.Continuation?
        func missionStream(id: String) -> AsyncStream<Mission?> {
            AsyncStream { self.missionCont = $0; $0.yield(self.initialMission) }
        }
        func conversationOriginStream(id: String) -> AsyncStream<JournalStore.ConversationOrigin> {
            AsyncStream {
                self.ownerCont = $0
                $0.yield(self.labels[id].map { .init(exists: true, label: $0) } ?? .unknown)
            }
        }
    }
    private final class Store: ItemsStoreReading, @unchecked Sendable {
        var itemCont: AsyncStream<TrackerItem?>.Continuation?
        func comments(itemID: String) throws -> [TrackerComment] { [] }
        func item(id: String) throws -> TrackerItem? { nil }
        func itemOutboxRows(itemID: String) throws -> [ItemOutboxRecord] { [] }
        func itemsStream(scope: ItemsScope) -> AsyncStream<[TrackerItem]> { AsyncStream { _ in } }
        func itemStream(id: String) -> AsyncStream<TrackerItem?> { AsyncStream { self.itemCont = $0 } }
        func commentsStream(itemID: String) -> AsyncStream<[TrackerComment]> { AsyncStream { _ in } }
        func itemOutboxStream(itemID: String) -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { $0.yield([]) } }
        func itemOutboxCreatesStream() -> AsyncStream<[ItemOutboxRecord]> { AsyncStream { _ in } }
    }
    private final class Sync: ItemsSyncing, @unchecked Sendable {
        func refresh(scope: ItemsScope) async -> ItemsRefreshOutcome { .succeeded }
        func refreshItem(id: String) async {}
        func enqueueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?) async {}
        func queueComment(itemID: String, localID: String, body: String, attachments: [TrackerAttachment]) async -> Bool { true }
        func enqueueCreate(localID: String, _ new: NewItem) async -> Bool { true }
        func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    }
    private final class API: ItemsProviding, @unchecked Sendable {
        func uploadMedia(_ data: Data, contentType: String) async throws -> String { fatalError() }
        func closeItem(id: String, resolution: ItemResolution, comment: String?) async throws -> TrackerItem { fatalError() }
        func reopenItem(id: String, comment: String?) async throws -> TrackerItem { fatalError() }
        func listItems(_ query: ItemsListQuery) async throws -> ItemsPage { fatalError() }
        func item(id: String) async throws -> (item: TrackerItem, comments: [TrackerComment]) { fatalError() }
        func createItem(_ new: NewItem, idempotencyKey: String?) async throws -> TrackerItem { fatalError() }
        func updateItem(id: String, _ patch: ItemPatch) async throws -> TrackerItem { fatalError() }
        func commentItem(id: String, body: String, attachments: [TrackerAttachment], action: String?, replyTo: String?, idempotencyKey: String?) async throws -> (item: TrackerItem, comment: TrackerComment) { fatalError() }
        func rankItem(id: String, _ change: ItemRankChange) async throws -> TrackerItem { fatalError() }
    }

    private struct TimedOut: Error {}
    private func waitUntil(_ cond: @escaping () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() {
            if Date() > deadline { XCTFail("timed out waiting", file: file, line: line); throw TimedOut() }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

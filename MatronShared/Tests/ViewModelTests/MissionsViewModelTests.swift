import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

private final class FakeMissionsStore: MissionsStoreReading, @unchecked Sendable {
    let missionsContinuation: AsyncStream<[Mission]>.Continuation
    let missionContinuation: AsyncStream<Mission?>.Continuation
    let milestonesContinuation: AsyncStream<[Milestone]>.Continuation
    let itemsContinuation: AsyncStream<[TrackerItem]>.Continuation
    let conversationsContinuation: AsyncStream<[MissionConversation]>.Continuation
    private let missionsStreamValue: AsyncStream<[Mission]>
    private let missionStreamValue: AsyncStream<Mission?>
    private let milestonesStreamValue: AsyncStream<[Milestone]>
    private let itemsStreamValue: AsyncStream<[TrackerItem]>
    private let conversationsStreamValue: AsyncStream<[MissionConversation]>

    init() {
        (missionsStreamValue, missionsContinuation) = AsyncStream<[Mission]>.makeStream()
        (missionStreamValue, missionContinuation) = AsyncStream<Mission?>.makeStream()
        (milestonesStreamValue, milestonesContinuation) = AsyncStream<[Milestone]>.makeStream()
        (itemsStreamValue, itemsContinuation) = AsyncStream<[TrackerItem]>.makeStream()
        (conversationsStreamValue, conversationsContinuation) = AsyncStream<[MissionConversation]>.makeStream()
    }

    /// The cached `A:bc` tags, by conversation id. A conversation missing
    /// from this map is one this device never synced.
    var tags: [String: SessionTagInputs] = [:]

    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missionsStreamValue }
    func missionStream(id: String) -> AsyncStream<Mission?> { missionStreamValue }
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> { milestonesStreamValue }
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> { itemsStreamValue }
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> { conversationsStreamValue }
    func sessionTag(convoID: String) -> SessionTagInputs? { tags[convoID] }
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] {
        tags.filter { convoIDs.contains($0.key) }
    }
}

private final class FakeMissionsSync: MissionsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var _refreshes = 0
    private var _refetches: [String] = []
    private var _closes: [(String, String)] = []
    private var _refreshMissionOutcome: MissionsRefreshOutcome = .succeeded
    private var _refreshOutcome: MissionsRefreshOutcome = .succeeded
    var closeError: Error?
    var supported: [Bool] = [true]
    var refreshes: Int { lock.withLock { _refreshes } }
    var refetches: [String] { lock.withLock { _refetches } }
    var closes: [(String, String)] { lock.withLock { _closes } }
    /// What the NEXT `refreshMission(id:)` returns — lets a test simulate a
    /// transport failure on the detail fetch (MAJOR-4).
    var refreshMissionOutcome: MissionsRefreshOutcome {
        get { lock.withLock { _refreshMissionOutcome } }
        set { lock.withLock { _refreshMissionOutcome = newValue } }
    }
    /// What the NEXT `refresh()` returns — lets a test simulate a list
    /// refresh recovering from an earlier failure.
    var refreshOutcome: MissionsRefreshOutcome {
        get { lock.withLock { _refreshOutcome } }
        set { lock.withLock { _refreshOutcome = newValue } }
    }

    func refresh() async -> MissionsRefreshOutcome { lock.withLock { _refreshes += 1; return _refreshOutcome } }
    func refreshMission(id: String) async -> MissionsRefreshOutcome {
        lock.withLock { _refetches.append(id) }
        return refreshMissionOutcome
    }
    func closeMission(id: String, summary: String) async throws -> Mission {
        lock.withLock { _closes.append((id, summary)) }
        if let closeError { throw closeError }
        return Mission(id: id, num: 61, state: .closed, title: "M61", closeSummary: summary, originConvoID: "c1")
    }
    func supportedStream() async -> AsyncStream<Bool> {
        let values = supported
        return AsyncStream { c in for v in values { c.yield(v) }; c.finish() }
    }
}

@MainActor
final class MissionsViewModelTests: XCTestCase {
    private func mission(_ id: String, num: Int, state: MissionState = .open, lastMilestoneAt: TimeInterval?,
                         needsYou: Int = 0, closedAt: TimeInterval? = nil) -> Mission {
        Mission(id: id, num: num, state: state, title: "M\(num)", originConvoID: "c1",
                createdAt: Date(timeIntervalSince1970: TimeInterval(num)),
                updatedAt: Date(timeIntervalSince1970: 2),
                lastMilestoneAt: lastMilestoneAt.map { Date(timeIntervalSince1970: $0) },
                closedAt: closedAt.map { Date(timeIntervalSince1970: $0) },
                openItems: needsYou, needsYou: needsYou)
    }

    func testSectionsSortOpenByActivityAndClosedByCloseTime() {
        let sections = MissionsListViewModel.sections(from: [
            mission("ms_1", num: 61, lastMilestoneAt: 10),
            mission("ms_2", num: 62, lastMilestoneAt: 30),
            mission("ms_3", num: 63, lastMilestoneAt: nil),
            mission("ms_4", num: 64, state: .closed, lastMilestoneAt: 20, closedAt: 40),
            mission("ms_5", num: 65, state: .closed, lastMilestoneAt: 5, closedAt: 50),
        ])
        XCTAssertEqual(sections.open.map(\.id), ["ms_2", "ms_1", "ms_3"], "newest milestone first, never-checkpointed last")
        XCTAssertEqual(sections.closed.map(\.id), ["ms_5", "ms_4"], "newest close first")
    }

    func testListPublishesSectionsBadgeAndSupport() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionsListViewModel(store: store, sync: sync)
        vm.start()
        store.missionsContinuation.yield([
            mission("ms_1", num: 61, lastMilestoneAt: 10, needsYou: 2),
            mission("ms_2", num: 62, state: .closed, lastMilestoneAt: 5, closedAt: 9),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.open.map(\.id), ["ms_1"])
        XCTAssertEqual(vm.closed.map(\.id), ["ms_2"])
        XCTAssertEqual(vm.needsYouTotal, 2)
        XCTAssertTrue(vm.isSupported)
        vm.stop()
    }

    func testUnsupportedJournalFlipsTheFlagThatHidesTheTab() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        sync.supported = [true, false]
        let vm = MissionsListViewModel(store: store, sync: sync)
        vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(vm.isSupported)
        vm.stop()
    }

    func testDetailFiltersMilestonesToUserInputOnly() {
        let all = [
            Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "landed", convoID: "c1", seq: 10),
            Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan said", convoID: "c1", seq: 20),
        ]
        XCTAssertEqual(MissionDetailViewModel.filtered(all, showOnlyUserInput: false).map(\.id), ["ml_1", "ml_2"])
        XCTAssertEqual(MissionDetailViewModel.filtered(all, showOnlyUserInput: true).map(\.id), ["ml_2"])
    }

    func testDetailRefetchesOnStartAndPublishesEveryStream() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        // `c9` is deliberately absent: a milestone posted in a conversation
        // this device never synced must still render, just without a tag.
        store.tags = ["c1": SessionTagInputs(boxLetter: "D", boxName: "dev-2", sessionShort: "bc")]
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        store.missionContinuation.yield(mission("ms_1", num: 61, lastMilestoneAt: 10))
        store.milestonesContinuation.yield([
            Milestone(id: "ml_2", missionID: "ms_1", num: 63, kind: .userInput, title: "Dan said", convoID: "c1", seq: 20),
            Milestone(id: "ml_1", missionID: "ms_1", num: 62, kind: .progress, title: "landed", convoID: "c9", seq: 10),
        ])
        store.itemsContinuation.yield([
            TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user, title: "needs you", originConvoID: "c1"),
        ])
        store.conversationsContinuation.yield([MissionConversation(id: "c1", title: "Session", box: "dev-2", state: "running")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.mission?.id, "ms_1")
        XCTAssertEqual(vm.milestones.map(\.id), ["ml_2", "ml_1"])
        XCTAssertEqual(vm.openItems.map(\.id), ["it_1"])
        XCTAssertEqual(vm.conversations.map(\.id), ["c1"])
        XCTAssertEqual(sync.refetches, ["ms_1"], "opening a page always refetches it")
        XCTAssertEqual(vm.sessionTags["c1"]?.boxLetter, "D")
        XCTAssertEqual(vm.sessionTags["c1"]?.sessionShort, "bc")
        XCTAssertNil(vm.sessionTags["c9"], "an unsynced conversation carries no tag rather than an empty one")
        vm.showOnlyUserInput = true
        XCTAssertEqual(vm.milestones.map(\.id), ["ml_2"])
        vm.stop()
    }

    /// The user's close is always allowed; the confirmation copy names how
    /// many items stay open so the override is deliberate and visible.
    func testCloseSendsTheSummaryAndReportsHowManyItemsWereOpen() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        store.missionContinuation.yield(mission("ms_1", num: 61, lastMilestoneAt: 10, needsYou: 2))
        store.itemsContinuation.yield([
            TrackerItem(id: "it_1", num: 64, kind: .question, awaiting: .user, title: "a", originConvoID: "c1"),
            TrackerItem(id: "it_2", num: 65, kind: .task, awaiting: .agent, title: "b", originConvoID: "c1"),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(vm.openItems.count, 2)
        vm.closeSummaryDraft = "  Shipped.  "
        await vm.close()
        XCTAssertEqual(sync.closes.map(\.0), ["ms_1"])
        XCTAssertEqual(sync.closes.map(\.1), ["Shipped."], "the summary is trimmed before it is sent")
        XCTAssertNil(vm.error)
        XCTAssertFalse(vm.isBusy)
        vm.stop()
    }

    func testCloseRefusesAnEmptySummaryAndSurfacesAServerFailure() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        vm.closeSummaryDraft = "   "
        await vm.close()
        XCTAssertEqual(sync.closes.count, 0)
        XCTAssertEqual(vm.error, "Write a short summary before closing the mission.")

        vm.error = nil
        vm.closeSummaryDraft = "Done."
        sync.closeError = JournalAPIError.transport("offline")
        await vm.close()
        XCTAssertEqual(sync.closes.count, 1)
        XCTAssertNotNil(vm.error)
        XCTAssertFalse(vm.isBusy)
        vm.stop()
    }

    /// A failed detail refresh must surface — the same alert plumbing
    /// `close()` failures already feed — rather than leave the page's
    /// "not on this device yet" placeholder permanent and un-retryable
    /// (MAJOR-4).
    func testFailedDetailRefreshSetsError() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        sync.refreshMissionOutcome = .failed(MissionsRefreshFailure(message: "offline"))
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        vm.start()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(vm.error)
        XCTAssertNil(vm.mission, "still nothing cached — the placeholder stays, now with a real error to retry against")
        vm.stop()
    }

    /// A pull-to-refresh (or reconnect refresh) that succeeds after an
    /// earlier failure must drop the stale banner — the cache is current
    /// again, so nothing left on screen should still say otherwise.
    func testListRefreshClearsStaleErrorOnSuccess() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionsListViewModel(store: store, sync: sync)
        sync.refreshOutcome = .failed(MissionsRefreshFailure(message: "offline"))
        await vm.refresh()
        XCTAssertEqual(vm.error, "offline")

        sync.refreshOutcome = .succeeded
        await vm.refresh()
        XCTAssertNil(vm.error, "a later successful refresh clears the earlier failure's banner")
    }

    /// Same shape on the detail page's retry path (MAJOR-4): a successful
    /// refetch after a failure must clear the error it set.
    func testDetailRefreshClearsStaleErrorOnSuccess() async throws {
        let store = FakeMissionsStore(); let sync = FakeMissionsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: sync)
        sync.refreshMissionOutcome = .failed(MissionsRefreshFailure(message: "offline"))
        await vm.refresh()
        XCTAssertEqual(vm.error, "offline")

        sync.refreshMissionOutcome = .succeeded
        await vm.refresh()
        XCTAssertNil(vm.error, "a later successful refetch clears the earlier failure's banner")
    }

}

/// `JournalStore.sessionTags(convoIDs:)` restates
/// `JournalChatService.roomTags` (that one is internal to `MatronChat`,
/// unreachable from here) so the mission page can tag a milestone's
/// conversation without a `MatronChat` dependency. Bugbot: it used to
/// carry only the single-box `run` halves, so a genuine multi-agent room
/// rendered on the mission page as an owner-box `A:bc` — or nothing at
/// all, once `MissionDetailView` starts trying `.room` first — instead of
/// `A↔B:bc`. Same store-backed setup as `JournalChatServiceTests`:
/// participants round-trip through the real snapshot path into the record
/// this reads.
final class JournalStoreSessionTagsRoomTests: XCTestCase {
    private func makeStore() throws -> JournalStore { try JournalStore(databaseURL: nil, ownSender: "user:dan") }

    func testSessionTagsCarriesRoomHalvesForAGenuineMultiAgentRoomAndFallsBackOtherwise() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-y"), AgentDTO(id: 9, name: "dev-z")])
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "room", title: "↔️ [ab] mac ↔ dev-z", sessionState: "waiting",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7,
                            participants: [7, 9]),
            ConvoSummaryDTO(id: "local", title: "↔️ [cd] mac ↔ mac", sessionState: "waiting",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7,
                            participants: [7]),
        ], headSeq: 1)

        let tags = store.sessionTags(convoIDs: ["room", "local"])

        // A genuine multi-box room carries both halves — names in
        // journal order, letters resolved through the same
        // `SessionTag.boxLetters` map the chat list uses — so
        // `MissionDetailView` can render `SessionTagText.room` for it.
        XCTAssertEqual(tags["room"]?.roomBoxNames, ["dev-y", "dev-z"])
        XCTAssertEqual(tags["room"]?.roomBoxShorts.count, 2)
        XCTAssertEqual(tags["room"]?.sessionShort, "ab")

        // A local room's two ends share one box: same gate as the chat
        // list — no room halves, falls back to the single-box tag.
        XCTAssertEqual(tags["local"]?.roomBoxNames, [])
    }

    func testSessionTagsOmitsRoomHalvesForASingleBoxUser() throws {
        let store = try makeStore()
        try store.replaceAgents([AgentDTO(id: 7, name: "dev-y")])
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "room", title: "↔️ [ab] mac ↔ dev-z", sessionState: "waiting",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7,
                            participants: [7, 9]),
        ], headSeq: 1)

        let tags = store.sessionTags(convoIDs: ["room"])

        // Same two-box gate as the single-box tag: one known box means
        // nothing to disambiguate, so no room halves even though the
        // conversation itself carries two participant ids.
        XCTAssertEqual(tags["room"]?.roomBoxNames, [])
    }
}

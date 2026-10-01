#if os(macOS)
import XCTest
import SwiftUI
import AppKit
@testable import MatronMac
import MatronChat
import MatronModels
import MatronViewModels
import MatronJournal

/// The mission page's session feeds across dashboard-model changes, and
/// what does (and does not) re-render the page.
@MainActor
final class MacMissionPageFeedTests: XCTestCase {
    private typealias F = MacMissionPageFixtures

    // MARK: Session feeds

    /// A session switch replaces the shell's dashboard model: the page
    /// detaches its feeds from the old one and attaches them to the new.
    func testASessionSwitchMovesTheFeedsToTheNewModel() async {
        let a = DashboardHarness(), b = DashboardHarness()
        a.vm.start(); b.vm.start()
        var attached = MacMissionPage.moveSessionFeeds(from: nil, to: a.vm, missionID: "ms_1")
        XCTAssertTrue(attached === a.vm)
        XCTAssertEqual(a.summaries.open, 1)
        attached = MacMissionPage.moveSessionFeeds(from: attached, to: b.vm, missionID: "ms_1")
        XCTAssertTrue(attached === b.vm)
        await waitUntil { a.summaries.open == 0 }
        XCTAssertEqual(b.summaries.open, 1, "the new session's model feeds the page")
        // Same model, another mission: nothing is torn down.
        attached = MacMissionPage.moveSessionFeeds(from: attached, to: b.vm, missionID: "ms_2")
        XCTAssertEqual(b.summaries.opened, 1)
        XCTAssertEqual(b.summaries.open, 1)
        a.vm.stop(); b.vm.stop()
    }

    /// The shell creates the dashboard model in a `.task` that can run
    /// after the page appeared: the page attaches once it arrives.
    func testADashboardModelArrivingLateStillGetsTheFeeds() {
        let a = DashboardHarness()
        a.vm.start()
        var attached = MacMissionPage.moveSessionFeeds(from: nil, to: nil, missionID: "ms_1")
        XCTAssertNil(attached)
        attached = MacMissionPage.moveSessionFeeds(from: attached, to: a.vm, missionID: "ms_1")
        XCTAssertEqual(a.summaries.open, 1)
        a.vm.stop()
    }

    /// The dashboard's `onDisappear` can land after the page's appear when
    /// one replaces the other: the page's feeds survive it.
    func testThePageAppearingBeforeTheDashboardDisappearsKeepsTheFeeds() {
        let a = DashboardHarness()
        a.vm.start()
        a.vm.pageDidAppear()
        MacMissionPage.moveSessionFeeds(from: nil, to: a.vm, missionID: "ms_1")
        a.vm.pageDidDisappear()
        XCTAssertEqual(a.summaries.open, 1)
        XCTAssertEqual(a.summaries.opened, 1, "one pipeline throughout")
        a.vm.missionPageDidDisappear()
        a.vm.stop()
    }

    /// A mission switch attaches the session feeds for the new mission at
    /// once, but the detail model for it lands later (in `.task`): until
    /// it does, the old mission's model must not render beside the new
    /// mission's sessions.
    func testAnotherMissionsDetailModelIsNotRendered() {
        let detail = DetailHarness()
        XCTAssertTrue(MacMissionPage.pageViewModel(detail.vm, missionID: "ms_1") === detail.vm)
        XCTAssertNil(MacMissionPage.pageViewModel(detail.vm, missionID: "ms_2"),
                     "the old mission's model waits behind the spinner")
        XCTAssertNil(MacMissionPage.pageViewModel(nil, missionID: "ms_1"))
    }

    // MARK: Re-renders

    /// Another mission's sessions changing does not re-evaluate the page;
    /// its own do (the positive control), and so does a milestone filter.
    func testOnlyThisMissionsChangesReRenderThePage() async throws {
        let dashboard = DashboardHarness()
        dashboard.vm.start()
        dashboard.missions.yield([F.mission, Mission(id: "ms_2", num: 2, title: "Other", originConvoID: "c-o")])
        dashboard.conversations.yield(["ms_1": [convo("a")], "ms_2": [convo("b")]])
        let detail = DetailHarness()
        detail.vm.start()
        detail.mission.yield(F.mission)
        detail.milestones.yield(F.milestones)
        detail.items.yield(F.openItems)
        await waitUntil { !dashboard.vm.cards.isEmpty }
        MacMissionPage.moveSessionFeeds(from: nil, to: dashboard.vm, missionID: "ms_1")

        let suite = "MacMissionPageFeedTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = NSHostingView(rootView: MacMissionPageBody(viewModel: detail.vm, missionsViewModel: dashboard.vm,
                                                             onOpenMilestone: { _, _ in }, onOpenItem: { _ in },
                                                             onOpenConversation: { _ in }, store: defaults)
            .frame(width: 1_200, height: 900)
            .environment(\.macMissionPageClock, F.now))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 900), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        await settle(host)
        XCTAssertEqual(dashboard.vm.pageMissionSessions.map(\.id), ["a"])

        let before = MacMissionPageBody.evaluations
        dashboard.conversations.yield(["ms_1": [convo("a")], "ms_2": [convo("b"), convo("c")]])
        await waitUntil { dashboard.vm.cards.first { $0.id == "ms_2" }?.sessions.count == 2 }
        detail.vm.closeSummaryDraft = "typing in the close sheet"
        await settle(host)
        XCTAssertEqual(MacMissionPageBody.evaluations, before,
                       "another mission's sessions (and the old close draft) never re-render the page")

        dashboard.conversations.yield(["ms_1": [convo("a"), convo("d")], "ms_2": [convo("b"), convo("c")]])
        await waitUntil { dashboard.vm.pageMissionSessions.count == 2 }
        await settle(host)
        XCTAssertGreaterThan(MacMissionPageBody.evaluations, before, "this mission's own sessions do")
        let afterOwn = MacMissionPageBody.evaluations
        detail.vm.showOnlyUserInput = true
        await settle(host)
        XCTAssertGreaterThan(MacMissionPageBody.evaluations, afterOwn, "and so does the milestone filter")
        detail.vm.stop(); dashboard.vm.stop()
    }

    private func convo(_ id: String) -> MissionConversation {
        MissionConversation(id: id, title: "", box: nil, state: "running")
    }

    private func settle(_ view: NSView) async {
        for _ in 0..<5 {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}

// MARK: Fakes

/// A dashboard model over controllable streams, counting chat-summaries
/// subscriptions (the feed the page keeps alive).
@MainActor
private final class DashboardHarness {
    let summaries = SummariesCounter()
    let missions: AsyncStream<[Mission]>.Continuation
    let conversations: AsyncStream<[String: [MissionConversation]]>.Continuation
    let vm: MissionsDashboardViewModel

    init() {
        let (missionsStream, missions) = AsyncStream<[Mission]>.makeStream()
        let (conversationsStream, conversations) = AsyncStream<[String: [MissionConversation]]>.makeStream()
        self.missions = missions; self.conversations = conversations
        let counter = summaries
        vm = MissionsDashboardViewModel(
            store: FakeDashboardStore(missions: missionsStream, conversations: conversationsStream),
            sync: FakeMissionsSync(), summaries: { counter.make() }, roster: { [:] }, send: { _, _ in })
    }
}

private final class SummariesCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _opened = 0, _open = 0
    var opened: Int { lock.withLock { _opened } }
    var open: Int { lock.withLock { _open } }
    func make() -> AsyncThrowingStream<[ChatSummary], Error> {
        let (stream, continuation) = AsyncThrowingStream<[ChatSummary], Error>.makeStream()
        continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._open -= 1 } }
        lock.withLock { _opened += 1; _open += 1 }
        return stream
    }
}

private final class FakeDashboardStore: MissionsDashboardStoreReading, @unchecked Sendable {
    let missions: AsyncStream<[Mission]>
    let conversations: AsyncStream<[String: [MissionConversation]]>
    init(missions: AsyncStream<[Mission]>, conversations: AsyncStream<[String: [MissionConversation]]>) {
        self.missions = missions; self.conversations = conversations
    }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { missions }
    func allMissionConversationsStream() -> AsyncStream<[String: [MissionConversation]]> { conversations }
    func latestMilestonesStream() -> AsyncStream<[String: Milestone]> { AsyncStream { _ in } }
    func needsYouItemsByMissionStream() -> AsyncStream<[String: [TrackerItem]]> { AsyncStream { _ in } }
    func latestSummaryTOCsStream() -> AsyncStream<[String: String]> { AsyncStream { _ in } }
    func sessionStatesStream() -> AsyncStream<[String: String]> { AsyncStream { _ in } }
}

private final class FakeMissionsSync: MissionsSyncing, @unchecked Sendable {
    func refresh() async -> MissionsRefreshOutcome { .succeeded }
    func refreshMission(id: String) async -> MissionsRefreshOutcome { .succeeded }
    func closeMission(id: String, summary: String) async throws -> Mission { F.mission }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.finish() } }
    private typealias F = MacMissionPageFixtures
}

/// A mission detail model over controllable streams.
@MainActor
private final class DetailHarness {
    let mission: AsyncStream<Mission?>.Continuation
    let milestones: AsyncStream<[Milestone]>.Continuation
    let items: AsyncStream<[TrackerItem]>.Continuation
    let vm: MissionDetailViewModel

    init() {
        let (missionStream, mission) = AsyncStream<Mission?>.makeStream()
        let (milestonesStream, milestones) = AsyncStream<[Milestone]>.makeStream()
        let (itemsStream, items) = AsyncStream<[TrackerItem]>.makeStream()
        self.mission = mission; self.milestones = milestones; self.items = items
        vm = MissionDetailViewModel(missionID: "ms_1",
                                    store: FakeDetailStore(mission: missionStream, milestones: milestonesStream,
                                                           items: itemsStream),
                                    sync: FakeMissionsSync())
    }
}

private final class FakeDetailStore: MissionsStoreReading, @unchecked Sendable {
    let mission: AsyncStream<Mission?>
    let milestones: AsyncStream<[Milestone]>
    let items: AsyncStream<[TrackerItem]>
    init(mission: AsyncStream<Mission?>, milestones: AsyncStream<[Milestone]>, items: AsyncStream<[TrackerItem]>) {
        self.mission = mission; self.milestones = milestones; self.items = items
    }
    func missionsStream(state: MissionState?) -> AsyncStream<[Mission]> { AsyncStream { _ in } }
    func missionStream(id: String) -> AsyncStream<Mission?> { mission }
    func milestonesStream(missionID: String) -> AsyncStream<[Milestone]> { milestones }
    func itemsStream(missionID: String) -> AsyncStream<[TrackerItem]> { items }
    func missionConversationsStream(missionID: String) -> AsyncStream<[MissionConversation]> { AsyncStream { _ in } }
    func sessionTag(convoID: String) -> SessionTagInputs? { nil }
    func sessionTags(convoIDs: Set<String>) -> [String: SessionTagInputs] { [:] }
    func sessionStatesStream() -> AsyncStream<[String: String]> { AsyncStream { _ in } }
}
#endif

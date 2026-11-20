import XCTest
import MatronChat
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class MissionsDashboardProjectsTests: XCTestCase {
    private func make() -> (MissionsDashboardViewModel, FakeDashboardStoreForProjects, FakeProjectsSync) {
        let store = FakeDashboardStoreForProjects()
        let projects = FakeProjectsSync()
        let vm = MissionsDashboardViewModel(
            store: store, sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { RosterSnapshot() }, send: { _, _ in },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            projects: projects)
        return (vm, store, projects)
    }

    func testProjectsSupportFollowsTheSync() async {
        let (vm, _, projects) = make()
        vm.start()
        await waitForProjects { vm.projectsSupported == true }
        projects.supported.send(false)
        await waitForProjects { vm.projectsSupported == false }
        vm.stop()
    }

    func testRefreshAlsoRefreshesProjects() async {
        let (vm, _, projects) = make()
        await vm.refresh()
        XCTAssertGreaterThanOrEqual(projects.refreshCalls, 1)
    }

    /// Preflight R4: project create, PATCH, status and close emit no
    /// marker, so a Projects surface appearing re-reads `GET /projects`.
    func testPageAppearRefreshesProjects() async {
        let (vm, _, projects) = make()
        vm.pageDidAppear()
        await waitForProjects { projects.refreshCalls >= 1 }
        let before = projects.refreshCalls
        vm.projectPageDidAppear()
        await waitForProjects { projects.refreshCalls > before }
        vm.projectPageDidDisappear()
        vm.pageDidDisappear()
    }

    /// Review M7: one appear is one `GET /projects` — the roster loop the
    /// appear starts does not fire its own on the first iteration.
    func testAnAppearRefreshesProjectsOnce() async {
        let (vm, _, projects) = make()
        vm.pageDidAppear()
        await waitForProjects { projects.refreshCalls >= 1 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projects.refreshCalls, 1)
        vm.pageDidDisappear()
        vm.projectPageDidAppear()
        await waitForProjects { projects.refreshCalls >= 2 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projects.refreshCalls, 2)
        vm.projectPageDidDisappear()
    }

    /// Review M7: once an old journal has answered 404, appearing again
    /// does not ask it again.
    func testAnOldJournalIsNotAskedOnAppear() async {
        let (vm, _, projects) = make()
        vm.start()
        projects.supported.send(false)
        await waitForProjects { vm.projectsSupported == false }
        try? await Task.sleep(for: .milliseconds(50))
        let settled = projects.refreshCalls
        vm.pageDidAppear()
        vm.projectPageDidAppear()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projects.refreshCalls, settled)
        vm.projectPageDidDisappear()
        vm.pageDidDisappear()
        vm.stop()
    }

    /// Preflight R4: the 60 s roster tick re-reads projects while a
    /// Projects surface stays visible, and stops once none is.
    func testTheRosterTickRefreshesProjectsWhileVisible() async {
        let store = FakeDashboardStoreForProjects()
        let projects = FakeProjectsSync()
        let vm = MissionsDashboardViewModel(
            store: store, sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { RosterSnapshot() }, send: { _, _ in }, rosterInterval: .milliseconds(20),
            projects: projects)
        vm.projectPageDidAppear()
        await waitForProjects { projects.refreshCalls >= 4 }
        vm.projectPageDidDisappear()
        try? await Task.sleep(for: .milliseconds(60))
        let settled = projects.refreshCalls
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projects.refreshCalls, settled, "no tick once the page is gone")
    }

    /// A mission page keeps the roster loop alive but shows no project, so
    /// its ticks leave `GET /projects` alone.
    func testAMissionPageTickDoesNotRefreshProjects() async {
        let store = FakeDashboardStoreForProjects()
        let projects = FakeProjectsSync()
        let rosterCalls = CallCounter()
        let vm = MissionsDashboardViewModel(
            store: store, sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { rosterCalls.bump(); return RosterSnapshot() }, send: { _, _ in },
            rosterInterval: .milliseconds(20),
            projects: projects)
        vm.missionPageDidAppear(missionID: "ms_1")
        await waitForProjects { rosterCalls.count >= 3 }
        vm.missionPageDidDisappear()
        XCTAssertEqual(projects.refreshCalls, 0)
    }

    /// Bugbot 281-1: project B's page appears before project A's
    /// disappears (a push over A, or a replacement): the feeds keep running
    /// while B shows, and stop once the last page goes.
    func testOverlappingProjectPagesKeepTheFeedsUntilTheLastLeaves() async {
        let (vm, _, _) = make()
        vm.start()
        vm.projectPageDidAppear()   // A
        vm.projectPageDidAppear()   // B, before A's disappear
        vm.projectPageDidDisappear() // A
        XCTAssertTrue(vm.isRosterLoopLive, "B is still on screen")
        XCTAssertTrue(vm.isSummariesFeedLive)
        vm.projectPageDidDisappear() // B
        XCTAssertFalse(vm.isRosterLoopLive)
        XCTAssertFalse(vm.isSummariesFeedLive)
        vm.projectPageDidDisappear() // a stray extra disappear
        XCTAssertEqual(vm.projectPagesShown, 0, "never below zero")
        vm.projectPageDidAppear()
        XCTAssertTrue(vm.isRosterLoopLive, "one appear after a stray disappear still counts")
        vm.projectPageDidDisappear()
        XCTAssertFalse(vm.isRosterLoopLive)
        vm.stop()
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func bump() { lock.withLock { value += 1 } }
}

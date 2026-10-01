import XCTest
import MatronChat
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class MissionsDashboardProjectsTests: XCTestCase {
    private func make() -> (MissionsDashboardViewModel, FakeDashboardStoreForProjects, FakeProjectsStore, FakeProjectsSync) {
        let store = FakeDashboardStoreForProjects()
        let projectsStore = FakeProjectsStore()
        let projects = FakeProjectsSync()
        let vm = MissionsDashboardViewModel(
            store: store, sync: FakeMissionsSyncForProjects(),
            summaries: { AsyncThrowingStream { $0.yield([]) } },
            roster: { RosterSnapshot() }, send: { _, _ in },
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            projectsStore: projectsStore, projects: projects)
        return (vm, store, projectsStore, projects)
    }

    func testHomeAssemblesFromProjectsAndMissions() async {
        let (vm, store, projectsStore, _) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo")])
        store.missions.send([Mission(id: "ms_1", num: 10, title: "Filed", originConvoID: "c1", projectID: "pj_1"),
                             Mission(id: "ms_2", num: 11, title: "Loose", originConvoID: "c1", activity: .running)])
        store.needsYou.send([:])
        await waitForProjects { vm.home.cards.count == 1 && vm.home.unfiled.count == 1 }
        XCTAssertEqual(vm.home.cards.first?.id, "pj_1")
        XCTAssertEqual(vm.home.unfiled.first?.id, "ms_2")
        vm.stop()
    }

    func testProjectsSupportFollowsTheSync() async {
        let (vm, _, _, projects) = make()
        vm.start()
        await waitForProjects { vm.projectsSupported == true }
        projects.supported.send(false)
        await waitForProjects { vm.projectsSupported == false }
        XCTAssertFalse(vm.canCreateProject)
        vm.stop()
    }

    func testRefreshAlsoRefreshesProjects() async {
        let (vm, _, _, projects) = make()
        await vm.refresh()
        XCTAssertGreaterThanOrEqual(projects.refreshCalls, 1)
    }

    func testCreateProjectTrimsAndRejectsAnEmptyTitle() async {
        let (vm, _, _, projects) = make()
        let none = await vm.createProject(title: "   ", body: nil)
        XCTAssertNil(none)
        XCTAssertEqual(vm.error, "Give the project a title.")
        vm.error = nil
        let made = await vm.createProject(title: "  Promo launch ", body: "site")
        XCTAssertEqual(made?.title, "Promo launch")
        XCTAssertEqual(projects.created.first?.0, "Promo launch")
    }

    /// Preflight R6: the journal answers 400 over its 200 UTF-16 unit title cap.
    func testCreateProjectRejectsATitleOverTheJournalsCap() async {
        let (vm, _, _, projects) = make()
        let long = await vm.createProject(title: String(repeating: "é", count: 201), body: nil)
        XCTAssertNil(long)
        XCTAssertEqual(vm.error, "Keep the title to 200 characters or fewer.")
        XCTAssertTrue(projects.created.isEmpty)
        vm.error = nil
        let atCap = await vm.createProject(title: String(repeating: "a", count: 200), body: nil)
        XCTAssertEqual(atCap?.title.utf16.count, 200)
        // An emoji is two UTF-16 units: 101 of them is 202, over the cap.
        let emoji = await vm.createProject(title: String(repeating: "😀", count: 101), body: nil)
        XCTAssertNil(emoji)
        XCTAssertEqual(projects.created.count, 1)
    }

    /// Preflight R4: project create, PATCH, status and close emit no
    /// marker, so a Projects surface appearing re-reads `GET /projects`.
    func testPageAppearRefreshesProjects() async {
        let (vm, _, _, projects) = make()
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
        let (vm, _, _, projects) = make()
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
        let (vm, _, _, projects) = make()
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
            projectsStore: FakeProjectsStore(), projects: projects)
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
            projectsStore: FakeProjectsStore(), projects: projects)
        vm.missionPageDidAppear(missionID: "ms_1")
        await waitForProjects { rosterCalls.count >= 3 }
        vm.missionPageDidDisappear()
        XCTAssertEqual(projects.refreshCalls, 0)
    }

    func testMoveMissionFilesThroughTheSyncAndReportsFailure() async {
        let (vm, store, projectsStore, projects) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo")])
        store.missions.send([Mission(id: "ms_1", num: 10, title: "Loose", originConvoID: "c1")])
        store.needsYou.send([:])
        await waitForProjects { vm.home.cards.count == 1 }
        await vm.moveMission("ms_1", to: "pj_1")
        XCTAssertEqual(projects.filed.first?.0, "ms_1"); XCTAssertEqual(projects.filed.first?.1, "pj_1")
        projects.failWrites = JournalAPIError.http(status: 403, message: "not yours")
        await vm.moveMission("ms_1", to: nil)
        XCTAssertNotNil(vm.error)
        vm.stop()
    }

    /// Bugbot 280-3: a stale menu entry naming a closed or unknown project
    /// is refused locally, like the project and mission pages do.
    func testMoveMissionRefusesAClosedOrUnknownTarget() async {
        let (vm, store, projectsStore, projects) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo"),
                                     Project(id: "pj_3", num: 3, state: .closed, title: "Old")])
        store.missions.send([Mission(id: "ms_1", num: 10, title: "Loose", originConvoID: "c1")])
        store.needsYou.send([:])
        await waitForProjects { vm.home.cards.count == 1 }
        await vm.moveMission("ms_1", to: "pj_3")
        await vm.moveMission("ms_1", to: "pj_nope")
        XCTAssertTrue(projects.filed.isEmpty, "closed and unknown targets are refused")
        XCTAssertNil(vm.error)
        await vm.moveMission("ms_1", to: "pj_1")
        await vm.moveMission("ms_1", to: nil)
        XCTAssertEqual(projects.filed.map(\.1), ["pj_1", nil])
        vm.stop()
    }

    /// Bugbot 281-1: project B's page appears before project A's
    /// disappears (a push over A, or a replacement): the feeds keep running
    /// while B shows, and stop once the last page goes.
    func testOverlappingProjectPagesKeepTheFeedsUntilTheLastLeaves() async {
        let (vm, _, _, _) = make()
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

import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class ProjectDetailViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make(_ id: String = "pj_1", refreshInterval: Duration = .seconds(60))
        -> (ProjectDetailViewModel, FakeProjectsStore, FakeProjectsSync, FakeMissionsSyncForProjects) {
        let store = FakeProjectsStore(), projects = FakeProjectsSync(), missions = FakeMissionsSyncForProjects()
        let now = self.now
        let vm = ProjectDetailViewModel(projectID: id, store: store, projects: projects, missions: missions,
                                        now: { now }, refreshInterval: refreshInterval)
        return (vm, store, projects, missions)
    }

    func testPageAssemblesFromTheStreams() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.projects.send([Project(id: "pj_1", num: 1, title: "Promo"), Project(id: "pj_2", num: 2, title: "Apps")])
        store.unfiled.send([Mission(id: "ms_9", num: 9, title: "Loose", originConvoID: "c1")])
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo", needsYou: 1))
        store.missions("pj_1").send([
            Mission(id: "ms_1", num: 10, title: "Open", originConvoID: "c1", projectID: "pj_1", activity: .running),
            Mission(id: "ms_2", num: 11, state: .closed, title: "Done", originConvoID: "c1", projectID: "pj_1"),
        ])
        store.needsYou("pj_1").send([TrackerItem(id: "it_1", num: 90, kind: .question, awaiting: .user, title: "Q",
                                                 originConvoID: "c1", missionID: "ms_1", missionNum: 10)])
        store.milestones("pj_1").send([Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress, title: "s",
                                                 convoID: "c1", seq: 1)])
        store.sessions("pj_1").send(["greg": 2])
        await waitForProjects { vm.page?.sessionsByBox == ["greg": 2] && vm.page?.recentMilestones.count == 1 }
        let page = try! XCTUnwrap(vm.page)
        XCTAssertEqual(page.missions.map(\.id), ["ms_1"])
        XCTAssertEqual(page.missions.first?.needsYouCount, 1)
        XCTAssertEqual(page.closedMissions.map(\.id), ["ms_2"])
        XCTAssertEqual(page.missionNums["ms_1"], 10)
        XCTAssertEqual(page.mergeTargets.map(\.id), ["pj_2"], "never itself")
        XCTAssertEqual(page.moveTargets.map(\.id), ["pj_1", "pj_2"], "every open project, this one ticked")
        XCTAssertEqual(page.unfiledMissions.map(\.id), ["ms_9"])
        vm.stop()
    }

    /// Preflight R5: a closed project offers no merge targets and no missions
    /// to add, but its missions can still move out into an open project.
    func testAClosedProjectOffersNoWrites() async {
        let (vm, store, projects, _) = make()
        vm.start()
        store.projects.send([Project(id: "pj_1", num: 1, state: .closed, title: "Promo"),
                             Project(id: "pj_2", num: 2, title: "Apps")])
        store.unfiled.send([Mission(id: "ms_9", num: 9, title: "Loose", originConvoID: "c1")])
        store.project("pj_1").send(Project(id: "pj_1", num: 1, state: .closed, title: "Promo"))
        await waitForProjects { vm.page?.project.state == .closed && vm.page?.moveTargets.isEmpty == false }
        XCTAssertEqual(vm.page?.mergeTargets, [])
        XCTAssertEqual(vm.page?.moveTargets.map(\.id), ["pj_2"], "open projects stay move targets")
        XCTAssertEqual(vm.page?.unfiledMissions, [])
        let merged = await vm.merge(into: "pj_2")
        XCTAssertFalse(merged)
        await vm.addMission("ms_9")
        await vm.moveMission("ms_9", to: "pj_1")
        XCTAssertTrue(projects.merged.isEmpty)
        XCTAssertTrue(projects.filed.isEmpty, "never files into a closed project")
        await vm.moveMission("ms_9", to: "pj_2")
        XCTAssertEqual(projects.filed.last?.1, "pj_2", "moving OUT of a closed project still works")
        vm.stop()
    }

    /// A stale menu entry naming a closed or unknown project is refused
    /// locally, like `MissionDetailViewModel.moveToProject`.
    func testMoveMissionRefusesAClosedOrUnknownTarget() async {
        let (vm, store, projects, _) = make()
        vm.start()
        store.projects.send([Project(id: "pj_1", num: 1, title: "Promo"), Project(id: "pj_2", num: 2, title: "Apps"),
                             Project(id: "pj_3", num: 3, state: .closed, title: "Old")])
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page?.moveTargets.count == 2 }
        await vm.moveMission("ms_1", to: "pj_3")
        await vm.moveMission("ms_1", to: "pj_nope")
        XCTAssertTrue(projects.filed.isEmpty, "closed and unknown targets are refused")
        await vm.moveMission("ms_1", to: "pj_2")
        await vm.moveMission("ms_1", to: nil)
        XCTAssertEqual(projects.filed.map(\.1), ["pj_2", nil])
        vm.stop()
    }

    /// Review Focus: the cached row says it was merged away.
    func testAMergedProjectRedirectsToItsTarget() async {
        let (vm, store, _, _) = make("pj_old")
        vm.start()
        store.project("pj_old").send(Project(id: "pj_old", num: 1, state: .closed, title: "Old", mergedInto: "pj_new"))
        await waitForProjects { vm.projectID == "pj_new" }
        await waitForProjects { store.project("pj_new").subscribers > 0 }
        store.project("pj_new").send(Project(id: "pj_new", num: 2, title: "New"))
        await waitForProjects { vm.page?.project.id == "pj_new" }
        vm.stop()
    }

    /// Review Focus: the server answers the old id with the target.
    func testTheServerRedirectSwitchesTheStreams() async {
        let (vm, store, projects, _) = make("pj_old")
        projects.projectOutcomes["pj_old"] = .loaded(projectID: "pj_new")
        vm.start()
        await waitForProjects { vm.projectID == "pj_new" }
        store.project("pj_new").send(Project(id: "pj_new", num: 2, title: "New"))
        await waitForProjects { vm.page?.project.title == "New" }
        vm.stop()
    }

    /// A refresh for the old id that answers after the page has already
    /// moved on (a merge from this page) must not drag it back.
    func testALateAnswerForTheOldProjectDoesNotUndoTheSwitch() async {
        let store = FakeProjectsStore(), gated = GatedProjectsSync()
        let vm = ProjectDetailViewModel(projectID: "pj_1", store: store, projects: gated,
                                        missions: FakeMissionsSyncForProjects(), now: { Date() })
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page != nil && gated.waiting == 1 }
        let merged = await vm.merge(into: "pj_2")
        XCTAssertTrue(merged)
        XCTAssertEqual(vm.projectID, "pj_2")
        gated.release(.notFound)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.projectID, "pj_2")
        XCTAssertFalse(vm.isMissing, "the not-found was about pj_1, not the page now shown")
        vm.stop()
    }

    func testNotFoundWithNothingCachedIsMissing() async {
        let (vm, _, projects, _) = make("pj_gone")
        projects.projectOutcomes["pj_gone"] = .notFound
        await vm.refresh()
        XCTAssertTrue(vm.isMissing)
    }

    /// pr4-review I1: with the page on screen, a failed refresh (the appear,
    /// every 60 s tick) keeps the page and raises no alert.
    func testAFailedRefreshWithThePageShownStaysSilent() async {
        let (vm, store, projects, _) = make(refreshInterval: .milliseconds(20))
        projects.projectOutcomes["pj_1"] = .failed(MissionsRefreshFailure(message: "Couldn't reach the server"))
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page != nil && projects.refreshedProjects.count >= 3 }
        XCTAssertNil(vm.error, "background refreshes never alert")
        XCTAssertFalse(vm.loadFailed, "the cached page is shown")
        XCTAssertEqual(vm.page?.project.title, "Promo")
        vm.stop()
    }

    /// Bugbot 281-2: nothing cached and the load failed is a state the host
    /// can draw (with Try again), not an endless spinner; a retry that
    /// works clears it.
    func testAFailedColdLoadReportsLoadFailedUntilARetryWorks() async {
        let (vm, store, projects, _) = make()
        store.missions("pj_1").send([]) // the detail pass reads the store's first emission
        projects.projectOutcomes["pj_1"] = .failed(MissionsRefreshFailure(message: "Couldn't reach the server"))
        await vm.refresh()
        XCTAssertTrue(vm.loadFailed)
        XCTAssertNil(vm.page)
        XCTAssertFalse(vm.isMissing)
        XCTAssertNil(vm.error, "the failed state is the page, not an alert")

        projects.projectOutcomes["pj_1"] = .loaded(projectID: "pj_1")
        await vm.refresh()
        XCTAssertFalse(vm.loadFailed, "Try again worked")

        // The store delivering the project clears it too (a list refresh
        // landed while the page sat on the failed state).
        projects.projectOutcomes["pj_1"] = .failed(MissionsRefreshFailure(message: "offline"))
        await vm.refresh()
        XCTAssertTrue(vm.loadFailed)
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page != nil }
        XCTAssertFalse(vm.loadFailed)
        vm.stop()
    }

    /// Explicit user actions still surface their errors.
    func testAFailedUserActionStillSetsError() async {
        let (vm, store, projects, _) = make()
        vm.start()
        store.projects.send([Project(id: "pj_1", num: 1, title: "Promo"), Project(id: "pj_2", num: 2, title: "Apps")])
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page?.moveTargets.count == 2 }
        projects.failWrites = URLError(.notConnectedToInternet)
        await vm.moveMission("ms_1", to: "pj_2")
        XCTAssertNotNil(vm.error)
        vm.error = nil
        let merged = await vm.merge(into: "pj_2")
        XCTAssertFalse(merged)
        XCTAssertNotNil(vm.error)
        vm.stop()
    }

    func testRefreshFetchesOpenMissionDetails() async {
        let (vm, store, _, missions) = make()
        vm.start()
        store.missions("pj_1").send([
            Mission(id: "ms_1", num: 10, title: "A", originConvoID: "c1", projectID: "pj_1"),
            Mission(id: "ms_2", num: 11, state: .closed, title: "B", originConvoID: "c1", projectID: "pj_1"),
        ])
        await waitForProjects { vm.hasMissions }
        await vm.refresh()
        XCTAssertEqual(missions.refreshedMissions.last, "ms_1")
        XCTAssertFalse(missions.refreshedMissions.contains("ms_2"), "closed missions need no session chips")
        vm.stop()
    }

    /// Preflight R4: the project is re-read on appear and on every tick
    /// while the page is visible, and not after it goes.
    func testTheTickRefreshesTheProjectWhileStarted() async {
        let (vm, _, projects, _) = make(refreshInterval: .milliseconds(20))
        vm.start()
        await waitForProjects { projects.refreshedProjects.count >= 3 }
        vm.stop()
        try? await Task.sleep(for: .milliseconds(30))
        let settled = projects.refreshedProjects.count
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(projects.refreshedProjects.count, settled)
        XCTAssertEqual(Set(projects.refreshedProjects), ["pj_1"])
    }

    private func makeClocked(_ id: String = "pj_1")
        -> (ProjectDetailViewModel, FakeProjectsStore, FakeProjectsSync, FakeMissionsSyncForProjects, TestClock) {
        let store = FakeProjectsStore(), projects = FakeProjectsSync(), missions = FakeMissionsSyncForProjects()
        let clock = TestClock(now)
        let vm = ProjectDetailViewModel(projectID: id, store: store, projects: projects, missions: missions,
                                        now: { clock.now })
        return (vm, store, projects, missions, clock)
    }

    private func openMission(_ id: String, project: String) -> Mission {
        Mission(id: id, num: 10, title: id, originConvoID: "c1", projectID: project)
    }

    /// pr3-review M6: a re-appear within the throttle re-reads the project
    /// but not every open mission's detail; past it, the full pass runs.
    func testAReAppearWithinTheThrottleSkipsTheMissionDetails() async {
        let (vm, store, projects, missions, clock) = makeClocked()
        store.missions("pj_1").send([openMission("ms_1", project: "pj_1"), openMission("ms_2", project: "pj_1")])
        vm.start()
        await waitForProjects { missions.refreshedMissions.count == 2 }
        vm.stop()

        clock.advance(30)
        vm.start()
        await waitForProjects { projects.refreshedProjects.count == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(missions.refreshedMissions.count, 2, "throttled: project only")
        vm.stop()

        clock.advance(31)
        vm.start()
        await waitForProjects { missions.refreshedMissions.count == 4 }
        XCTAssertEqual(projects.refreshedProjects.count, 3)
        vm.stop()
    }

    /// The throttle is per project, and a server redirect's detail pass is
    /// outside it — over the TARGET's missions read from the store, not the
    /// emptied `missions` of the page it left (PR2-M1).
    func testAServerRedirectRefreshesTheTargetsMissionsEvenWhenThrottled() async {
        let (vm, store, projects, missions, clock) = makeClocked("pj_old")
        store.missions("pj_old").send([openMission("ms_old", project: "pj_old")])
        store.missions("pj_new").send([openMission("ms_new", project: "pj_new")])
        vm.start()
        await waitForProjects { missions.refreshedMissions == ["ms_old"] }
        vm.stop()

        clock.advance(10)
        projects.projectOutcomes["pj_old"] = .loaded(projectID: "pj_new")
        vm.start()
        await waitForProjects { missions.refreshedMissions == ["ms_old", "ms_new"] }
        XCTAssertEqual(vm.projectID, "pj_new")
        vm.stop()
    }

    /// The cached-row redirect (`merged_into`) fetches the target and then
    /// its missions' details.
    func testACachedMergedRowRefreshesTheTargetsMissions() async {
        let (vm, store, _, missions, _) = makeClocked("pj_old")
        store.missions("pj_new").send([openMission("ms_new", project: "pj_new")])
        vm.start()
        store.project("pj_old").send(Project(id: "pj_old", num: 1, state: .closed, title: "Old", mergedInto: "pj_new"))
        await waitForProjects { missions.refreshedMissions.contains("ms_new") }
        vm.stop()
    }

    /// A merge from this page switches to the target and fetches its open
    /// missions' details, the throttle notwithstanding.
    func testAMergeFromHereRefreshesTheTargetsMissions() async {
        let (vm, store, _, missions, _) = makeClocked()
        store.missions("pj_1").send([openMission("ms_1", project: "pj_1")])
        store.missions("pj_2").send([openMission("ms_1", project: "pj_2"), openMission("ms_2", project: "pj_2")])
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page != nil && missions.refreshedMissions == ["ms_1"] }
        let merged = await vm.merge(into: "pj_2")
        XCTAssertTrue(merged)
        await waitForProjects { missions.refreshedMissions.count == 3 }
        XCTAssertEqual(Set(missions.refreshedMissions.dropFirst()), ["ms_1", "ms_2"])
        vm.stop()
    }

    // MARK: Feed (Projects view v2)

    private static func decision(_ n: Int) -> ProjectDecision {
        ProjectDecision(id: "it_\(n)", num: n, kind: .decision, title: "D\(n)",
                        createdAt: Date(timeIntervalSince1970: TimeInterval(n)))
    }
    private static func decisions(_ ns: ClosedRange<Int>, total: Int = 7, next: String?) -> ProjectFeedPage<ProjectDecision> {
        ProjectFeedPage(total: total, rows: ns.reversed().map(decision), nextBefore: next)
    }

    func testFeedFillsThePageAndAMissingOneHidesIt() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        store.projectFeed("pj_1").send(nil)
        await waitForProjects { vm.page != nil }
        XCTAssertEqual(vm.page?.hasFeed, false, "an older journal: no roll-up sections")
        XCTAssertEqual(vm.page?.decisions, ProjectFeedPage())
        let file = ProjectFile(blobID: "b", source: .item(num: 9), postedAt: Date(timeIntervalSince1970: 1))
        let milestone = ProjectMilestone(milestone: Milestone(id: "ml_1", missionID: "ms_1", num: 70, kind: .progress,
                                                              title: "s", convoID: "c1", seq: 1), missionNum: 10)
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(6...7, next: "c6"),
                                                   files: ProjectFeedPage(total: 1, rows: [file]),
                                                   milestones: ProjectFeedPage(total: 1, rows: [milestone])))
        await waitForProjects { vm.page?.hasFeed == true }
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [7, 6])
        XCTAssertEqual(vm.page?.decisions.total, 7)
        XCTAssertEqual(vm.page?.decisions.hasMore, true)
        XCTAssertEqual(vm.page?.files.rows, [file])
        XCTAssertEqual(vm.page?.milestonesPage.rows, [milestone])
        vm.stop()
    }

    /// `loadMore` pages on from `next_before`, appends, and stops once a
    /// page answers with no cursor — no further request.
    func testLoadMoreAppendsUntilNextBeforeIsNil() async {
        let (vm, store, projects, _) = make()
        projects.feedPages = ["c6": .decisions(Self.decisions(4...5, next: "c4")),
                              "c4": .decisions(Self.decisions(1...3, next: nil))]
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(6...7, next: "c6")))
        await waitForProjects { vm.page?.hasFeed == true }

        let first = await vm.loadMore(kind: .decisions)
        XCTAssertTrue(first)
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [7, 6, 5, 4])
        XCTAssertEqual(vm.page?.decisions.nextBefore, "c4")
        let second = await vm.loadMore(kind: .decisions)
        XCTAssertTrue(second)
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [7, 6, 5, 4, 3, 2, 1])
        XCTAssertNil(vm.page?.decisions.nextBefore)
        XCTAssertEqual(vm.page?.decisions.total, 7)
        let third = await vm.loadMore(kind: .decisions)
        XCTAssertFalse(third, "the last page has no cursor")
        XCTAssertEqual(projects.feedCalls.map(\.before), ["c6", "c4"])
        XCTAssertEqual(projects.feedCalls.map(\.kind), [.decisions, .decisions])
        XCTAssertEqual(projects.feedCalls.map(\.id), ["pj_1", "pj_1"])
        XCTAssertTrue(vm.loadingMore.isEmpty)

        let files = await vm.loadMore(kind: .files)
        XCTAssertFalse(files, "a kind whose first page is its last never asks")
        XCTAssertEqual(projects.feedCalls.count, 2)
        vm.stop()
    }

    func testLoadMoreWithoutAFeedOrAfterAFailureAppendsNothing() async {
        let (vm, store, projects, _) = make()
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        store.projectFeed("pj_1").send(nil)
        await waitForProjects { vm.page != nil }
        let none = await vm.loadMore(kind: .decisions)
        XCTAssertFalse(none)
        XCTAssertTrue(projects.feedCalls.isEmpty)

        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(6...7, next: "c6")))
        await waitForProjects { vm.page?.hasFeed == true }
        projects.failWrites = JournalAPIError.transport("offline")
        let failed = await vm.loadMore(kind: .decisions)
        XCTAssertFalse(failed)
        XCTAssertEqual(vm.page?.decisions.rows.count, 2)
        XCTAssertNil(vm.error, "a failed page load is not an alert")
        XCTAssertTrue(vm.loadingMore.isEmpty)
        vm.stop()
    }

    /// The minute tick re-reads the project. A new first page that still
    /// shares a row with the old one keeps the pages loaded past it, with
    /// the old first page folded in so nothing falls between (PR 294
    /// review: a busy project's list must not snap back to one page).
    func testANewOverlappingFirstPageKeepsLoadedPages() async {
        let (vm, store, projects, _) = make()
        projects.feedPages = ["c6": .decisions(Self.decisions(4...5, next: "c4")),
                              "c4": .decisions(Self.decisions(1...3, total: 8, next: nil))]
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(6...7, next: "c6")))
        await waitForProjects { vm.page?.hasFeed == true }
        _ = await vm.loadMore(kind: .decisions)
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [7, 6, 5, 4])

        // A new decision #8 arrives: #6 is pushed off the first page.
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(7...8, total: 8, next: "c7")))
        await waitForProjects { vm.page?.decisions.rows.first?.num == 8 }
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [8, 7, 6, 5, 4], "6 + loaded + 1, nothing lost")
        XCTAssertEqual(vm.page?.decisions.nextBefore, "c4", "paging carries on from the loaded cursor")
        let next = await vm.loadMore(kind: .decisions)
        XCTAssertTrue(next)
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [8, 7, 6, 5, 4, 3, 2, 1])
        vm.stop()
    }

    /// When more than a page arrived between reads (the two first pages
    /// share no row), the gap is real: the loaded pages go, and a page that
    /// lands after that, fetched from the old cursor, is dropped too.
    func testADisjointFirstPageDropsLoadedPagesAndALateAnswer() async {
        let (vm, store, projects, _) = make()
        projects.feedPages = ["c6": .decisions(Self.decisions(4...5, next: "c4")),
                              "c4": .decisions(Self.decisions(1...3, next: nil))]
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(6...7, next: "c6")))
        await waitForProjects { vm.page?.hasFeed == true }
        _ = await vm.loadMore(kind: .decisions)
        XCTAssertEqual(vm.page?.decisions.rows.count, 4)

        projects.blockNextFeed = true
        let late = Task { await vm.loadMore(kind: .decisions) }
        await waitForProjects { projects.isFeedGated }
        store.projectFeed("pj_1").send(ProjectFeed(decisions: Self.decisions(20...21, total: 21, next: "c20")))
        await waitForProjects { vm.page?.decisions.rows.first?.num == 21 }
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [21, 20], "no shared row: the loaded pages go")
        XCTAssertEqual(vm.page?.decisions.nextBefore, "c20")
        projects.releaseFeedGate()
        let appended = await late.value
        XCTAssertFalse(appended, "the answer hangs off a cursor the page no longer has")
        XCTAssertEqual(vm.page?.decisions.rows.map(\.num), [21, 20])
        vm.stop()
    }

    func testMergeSwitchesToTheTargetAndAddMissionFiles() async {
        let (vm, store, projects, _) = make()
        vm.start()
        store.project("pj_1").send(Project(id: "pj_1", num: 1, title: "Promo"))
        await waitForProjects { vm.page != nil }
        let merged = await vm.merge(into: "pj_2")
        XCTAssertTrue(merged)
        XCTAssertEqual(projects.merged.first?.1, "pj_2")
        XCTAssertEqual(vm.projectID, "pj_2")
        store.project("pj_2").send(Project(id: "pj_2", num: 2, title: "Apps"))
        await waitForProjects { vm.page?.project.id == "pj_2" }
        await vm.addMission("ms_9")
        XCTAssertEqual(projects.filed.last?.0, "ms_9"); XCTAssertEqual(projects.filed.last?.1, "pj_2")
        let selfMerge = await vm.merge(into: "pj_2")
        XCTAssertFalse(selfMerge, "a project never merges into itself")
        vm.stop()
    }
}

/// `refreshProject` parks until the test releases it; every write succeeds.
private final class GatedProjectsSync: ProjectsSyncing, @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [CheckedContinuation<ProjectRefreshOutcome, Never>] = []
    var waiting: Int { lock.withLock { parked.count } }
    func release(_ outcome: ProjectRefreshOutcome) {
        let all = lock.withLock { () -> [CheckedContinuation<ProjectRefreshOutcome, Never>] in
            defer { parked = [] }; return parked
        }
        for c in all { c.resume(returning: outcome) }
    }
    func refresh() async -> ProjectsRefreshOutcome { .succeeded }
    func refreshProject(id: String) async -> ProjectRefreshOutcome {
        await withCheckedContinuation { c in lock.withLock { parked.append(c) } }
    }
    func beginWatching(convoID: String) async {}
    func endWatching(convoID: String) async {}
    func createProject(title: String, body: String?) async throws -> Project { Project(id: "pj_x", num: 1, title: title) }
    func mergeProject(id: String, into: String) async throws {}
    func setMissionProject(missionID: String, project: String?) async throws -> Mission {
        Mission(id: missionID, num: 1, title: "M", originConvoID: "c1", projectID: project)
    }
    func supportedStream() async -> AsyncStream<Bool> { AsyncStream { $0.yield(true) } }
    func projectFeed(id: String, kind: ProjectFeedKind, before: String?, limit: Int?) async throws -> ProjectFeedSlice {
        throw JournalAPIError.notFound
    }
}

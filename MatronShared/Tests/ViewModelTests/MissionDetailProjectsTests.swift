import XCTest
import MatronModels
import MatronJournal
@testable import MatronViewModels

@MainActor
final class MissionDetailProjectsTests: XCTestCase {
    private func make() -> (MissionDetailViewModel, FakeMissionPageStore, FakeProjectsStore, FakeProjectsSync) {
        let store = FakeMissionPageStore(), projectsStore = FakeProjectsStore(), projects = FakeProjectsSync()
        let vm = MissionDetailViewModel(missionID: "ms_1", store: store, sync: FakeMissionsSyncForProjects(),
                                        projectsStore: projectsStore, projects: projects)
        return (vm, store, projectsStore, projects)
    }

    func testProjectAndMoveTargetsFollowTheStreams() async {
        let (vm, store, projectsStore, _) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo"),
                                     Project(id: "pj_x", num: 2, state: .closed, title: "Old")])
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: "pj_1"))
        await waitForProjects { vm.project?.id == "pj_1" }
        XCTAssertEqual(vm.moveTargets.map(\.id), ["pj_1"], "closed projects are not targets")
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1", projectID: nil))
        await waitForProjects { vm.project == nil }
        vm.stop()
    }

    func testConversationGroupsFollowTheMissionState() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"))
        store.conversations.send([MissionConversation(id: "c1", title: "S", box: nil, state: "running")])
        await waitForProjects { vm.conversationGroups.onItNow.count == 1 }
        store.mission.send(Mission(id: "ms_1", num: 61, state: .closed, title: "M", originConvoID: "c1"))
        await waitForProjects { vm.conversationGroups.earlier.count == 1 && vm.conversationGroups.onItNow.isEmpty }
        XCTAssertTrue(store.taggedIDs.contains("c1"), "conversation rows get their A:bc tags too")
        vm.stop()
    }

    /// Review I3: a session that finishes its turn stops being "running"
    /// on the mission page as soon as the store's session state flips, not
    /// at the next detail refetch — and On it now re-sorts.
    func testConversationGroupsFollowLiveSessionState() async {
        let (vm, store, _, _) = make()
        vm.start()
        store.mission.send(Mission(id: "ms_1", num: 61, title: "M", originConvoID: "c1"))
        store.conversations.send([
            MissionConversation(id: "c1", title: "A", box: nil, state: "running"),
            MissionConversation(id: "c2", title: "B", box: nil, state: "done"),
        ])
        await waitForProjects { vm.conversationGroups.onItNow.map(\.id) == ["c1", "c2"] }
        XCTAssertEqual(vm.conversationGroups.onItNow.first?.state, .running)
        store.sessionStates.send(["c1": "done", "c2": "running"])
        await waitForProjects { vm.conversationGroups.onItNow.map(\.id) == ["c2", "c1"] }
        XCTAssertEqual(vm.conversationGroups.onItNow.map(\.state), [.running, .done])
        vm.stop()
    }

    func testMoveToProjectFilesThroughTheSync() async {
        let (vm, _, projectsStore, projects) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_2", num: 2, title: "Promo")])
        await waitForProjects { vm.moveTargets.map(\.id) == ["pj_2"] }
        XCTAssertTrue(vm.canMove)
        await vm.moveToProject("pj_2")
        XCTAssertEqual(projects.filed.first?.0, "ms_1"); XCTAssertEqual(projects.filed.first?.1, "pj_2")
        projects.failWrites = JournalAPIError.forbidden
        await vm.moveToProject(nil)
        XCTAssertNotNil(vm.error)
        vm.stop()
    }

    func testMoveToProjectRefusesAClosedTarget() async {
        let (vm, _, projectsStore, projects) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo"),
                                     Project(id: "pj_x", num: 2, state: .closed, title: "Old")])
        await waitForProjects { vm.moveTargets.map(\.id) == ["pj_1"] }
        await vm.moveToProject("pj_x")
        XCTAssertTrue(projects.filed.isEmpty, "a closed project is never a valid move target")
        vm.stop()
    }

    func testMoveToProjectRefusesAnUnknownTarget() async {
        let (vm, _, projectsStore, projects) = make()
        vm.start()
        projectsStore.projects.send([Project(id: "pj_1", num: 1, title: "Promo")])
        await waitForProjects { vm.moveTargets.map(\.id) == ["pj_1"] }
        await vm.moveToProject("pj_unheard_of")
        XCTAssertTrue(projects.filed.isEmpty, "a project this device has never cached is never a valid move target")
        vm.stop()
    }

    func testMoveToProjectAllowsUnfiling() async {
        let (vm, _, _, projects) = make()
        await vm.moveToProject(nil)
        XCTAssertEqual(projects.filed.first?.0, "ms_1")
        XCTAssertNil(projects.filed.first?.1, "nil always unfiles, whatever allProjects holds")
    }
}

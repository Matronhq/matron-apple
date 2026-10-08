import XCTest
import MatronModels
@testable import Matron

/// The Memories screens on the Missions tab's stack (spec 2026-09-27
/// memories).
@MainActor
final class MemoriesNavigationTests: XCTestCase {
    func testRoutesRoundTripAndStayApartFromEveryOtherRoute() {
        XCTAssertEqual(MemoryRoute(id: "avoid-atlas").pathValue, "memory/avoid-atlas")
        XCTAssertEqual(MemoryRoute(pathValue: "memory/avoid-atlas"), MemoryRoute(id: "avoid-atlas"))
        XCTAssertNil(MemoryRoute(pathValue: MemoriesRoute.list))
        XCTAssertNil(MemoryRoute(pathValue: MemoriesRoute.newMemory))
        XCTAssertNil(MissionRoute(pathValue: MemoriesRoute.list))
        XCTAssertNil(ItemRoute(pathValue: "memory/avoid-atlas"))
        for value in [MemoriesRoute.list, MemoriesRoute.newMemory, "memory/avoid-atlas"] {
            XCTAssertTrue(MemoriesRoute.isMemoriesRoute(value), value)
            // A page, never a chat: the chat-sharing cut must skip it.
            XCTAssertTrue(isAnyPathPrefixedRoute(value), value)
        }
        XCTAssertFalse(MemoriesRoute.isMemoriesRoute("mission/ms_1"))
        XCTAssertFalse(MemoriesRoute.isMemoriesRoute("cv_1"))
    }

    func testABoxFileRouteRoundTripsItsBoxAndPath() {
        let ref = LocalMemoryRef(boxID: 42, path: "/home/alice/.claude/projects/-home-alice-app/memory/a-rule.md")
        let route = LocalMemoryRoute(ref: ref)
        XCTAssertEqual(route.pathValue, "boxmemory/42/home/alice/.claude/projects/-home-alice-app/memory/a-rule.md")
        XCTAssertEqual(LocalMemoryRoute(pathValue: route.pathValue)?.ref, ref)
        XCTAssertNil(LocalMemoryRoute(id: "not-a-box/home/x.md").ref)
        XCTAssertNil(LocalMemoryRoute(id: "42").ref)
        XCTAssertNil(LocalMemoryRoute(id: "42/").ref)
        // Apart from a journal memory's route, and a page, never a chat.
        XCTAssertNil(MemoryRoute(pathValue: route.pathValue))
        XCTAssertNil(LocalMemoryRoute(pathValue: "memory/avoid-atlas"))
        XCTAssertTrue(MemoriesRoute.isMemoriesRoute(route.pathValue))
        XCTAssertTrue(isAnyPathPrefixedRoute(route.pathValue))
    }

    func testOpeningABoxFileTwiceStacksItOnce_andAnOverlapOpensTheJournalMemoryOnTop() {
        let nav = AppShellNavigation()
        let ref = LocalMemoryRef(boxID: 42, path: "/home/alice/app/CLAUDE.md")
        nav.openMemories()
        nav.openLocalMemory(ref)
        nav.openLocalMemory(ref)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, "boxmemory/42/home/alice/app/CLAUDE.md"])
        XCTAssertTrue(nav.memoriesShown, "the list is still on the stack, so the section keeps what it read")
        nav.openMemory("avoid-atlas")
        XCTAssertEqual(nav.missionsPath.last, "memory/avoid-atlas")
    }

    func testOpenMemoriesSelectsMissionsAndReplacesItsStack() {
        let nav = AppShellNavigation()
        nav.missionsPath = ["mission/ms_1", "item/it_1"]
        nav.openMemories()
        XCTAssertEqual(nav.tab, .missions)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
        XCTAssertTrue(nav.memoriesShown)
    }

    /// No Missions tab to land on with an old journal (which predates
    /// `/memories` too).
    func testOpenMemoriesIsANoOpWithoutMissions() {
        let nav = AppShellNavigation()
        nav.missionsSupported = false
        nav.openMemories()
        XCTAssertEqual(nav.tab, .conversations)
        XCTAssertEqual(nav.missionsPath, [])
    }

    func testOpeningAMemoryTwiceStacksItOnce() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openMemory("avoid-atlas")
        nav.openMemory("avoid-atlas")
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, "memory/avoid-atlas"])
    }

    /// After a save, as the web tracker does: the new-memory form becomes
    /// that memory's editor.
    func testSavingANewMemoryOpensItsEditorInPlaceOfTheForm() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openNewMemory()
        nav.openNewMemory()
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, MemoriesRoute.newMemory])
        nav.memorySaved(name: "avoid-atlas", wasNew: true)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, "memory/avoid-atlas"])
    }

    func testSavingAnEditReturnsToTheList() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openMemory("avoid-atlas")
        nav.memorySaved(name: "avoid-atlas", wasNew: false)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
        // Never pops the list itself.
        nav.memorySaved(name: "avoid-atlas", wasNew: false)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
    }

    func testDeletingReturnsToTheList() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openMemory("avoid-atlas")
        nav.memoryDeleted()
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
        nav.memoryDeleted()
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
    }

    func testLeavingTheListHidesIt() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.missionsPath = []
        XCTAssertFalse(nav.memoriesShown)
    }
}

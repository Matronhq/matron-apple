import XCTest
@testable import Matron

/// The Memories screens on the Missions tab's stack (spec 2026-09-27
/// memories; decision #3948).
@MainActor
final class MemoriesNavigationTests: XCTestCase {
    func testRoutesRoundTripAndStayApartFromEveryOtherRoute() {
        XCTAssertEqual(MemoryRoute(id: "avoid-eric").pathValue, "memory/avoid-eric")
        XCTAssertEqual(MemoryRoute(pathValue: "memory/avoid-eric"), MemoryRoute(id: "avoid-eric"))
        XCTAssertNil(MemoryRoute(pathValue: MemoriesRoute.list))
        XCTAssertNil(MemoryRoute(pathValue: MemoriesRoute.newMemory))
        XCTAssertNil(MissionRoute(pathValue: MemoriesRoute.list))
        XCTAssertNil(ItemRoute(pathValue: "memory/avoid-eric"))
        for value in [MemoriesRoute.list, MemoriesRoute.newMemory, "memory/avoid-eric"] {
            XCTAssertTrue(MemoriesRoute.isMemoriesRoute(value), value)
            // A page, never a chat: the chat-sharing cut must skip it.
            XCTAssertTrue(isAnyPathPrefixedRoute(value), value)
        }
        XCTAssertFalse(MemoriesRoute.isMemoriesRoute("mission/ms_1"))
        XCTAssertFalse(MemoriesRoute.isMemoriesRoute("cv_1"))
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
        nav.openMemory("avoid-eric")
        nav.openMemory("avoid-eric")
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, "memory/avoid-eric"])
    }

    /// After a save, as the web tracker does: the new-memory form becomes
    /// that memory's editor.
    func testSavingANewMemoryOpensItsEditorInPlaceOfTheForm() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openNewMemory()
        nav.openNewMemory()
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, MemoriesRoute.newMemory])
        nav.memorySaved(name: "avoid-eric", wasNew: true)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list, "memory/avoid-eric"])
    }

    func testSavingAnEditReturnsToTheList() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openMemory("avoid-eric")
        nav.memorySaved(name: "avoid-eric", wasNew: false)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
        // Never pops the list itself.
        nav.memorySaved(name: "avoid-eric", wasNew: false)
        XCTAssertEqual(nav.missionsPath, [MemoriesRoute.list])
    }

    func testDeletingReturnsToTheList() {
        let nav = AppShellNavigation()
        nav.openMemories()
        nav.openMemory("avoid-eric")
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

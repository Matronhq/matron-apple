import XCTest
import SwiftUI
import UIKit
import MatronModels
@testable import Matron

/// App shell (spec §3). Renders the REAL shell in a scene-attached
/// `UIWindow` (the `SummariesSheetBindingTests` pattern): SwiftUI bridges
/// `TabView` to a `UITabBarController`, so the tab bar is a genuine
/// `UITabBar` we can find and inspect, unlike arbitrary body content.
@MainActor
final class AppShellViewTests: XCTestCase {
    private var window: UIWindow!
    /// Held so `tearDown()` can stop the session's background maintenance
    /// sweeper (M1 — the identical Mac defect fixed in
    /// `MacAppDependenciesTests`: a leaked `JournalMaintenance` 10 s timer
    /// otherwise outlives the test method). See
    /// `AppDependencies.stopMaintenanceForTests()`.
    private var deps: AppDependencies!

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        await deps?.stopMaintenanceForTests()
        deps = nil
        try await super.tearDown()
    }

    private func makeShell(navigation: AppShellNavigation) -> AppShellView {
        let session = UserSession(userID: "@a:s", deviceID: "D",
                                  homeserverURL: URL(string: "https://s")!, accessToken: "t")
        deps = AppDependencies()
        return AppShellView(session: session, deps: deps, onSignOut: {}, navigation: navigation)
    }

    /// Decision #2913: the Coordinator is a tab again, and the first one.
    func test_shell_showsFourTabs_coordinatorFirst() throws {
        renderInWindow(makeShell(navigation: AppShellNavigation()))
        let bar = try XCTUnwrap(findTabBar(in: window), "TabView must bridge to a UITabBar")
        XCTAssertEqual(bar.items?.map(\.title), ["Coordinator", "Missions", "Decisions", "Conversations"])
        XCTAssertFalse(bar.isHidden)
    }

    /// Opening the Coordinator's conversation selects its tab — no sheet
    /// goes up over the shell any more.
    func test_openingTheCoordinator_selectsItsTab_andPresentsNothing() throws {
        let nav = AppShellNavigation()
        renderInWindow(makeShell(navigation: nav))
        nav.coordinatorConvoID = "!coord:s"
        nav.openChat("!coord:s")
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let bar = try XCTUnwrap(findTabBar(in: window))
        XCTAssertEqual(bar.selectedItem?.title, "Coordinator")
        XCTAssertNil(window.rootViewController?.presentedViewController, "no Coordinator sheet")
    }

    func test_shell_opensOnConversations() {
        let nav = AppShellNavigation()
        renderInWindow(makeShell(navigation: nav))
        XCTAssertEqual(nav.tab, .conversations)
    }

    /// Spec §3: the tab bar shows only at the root of each tab.
    func test_pushedChat_hidesTheTabBar() throws {
        let nav = AppShellNavigation()
        nav.chatPath = ["!r:s"]
        renderInWindow(makeShell(navigation: nav))
        let bar = try XCTUnwrap(findTabBar(in: window))
        XCTAssertTrue(bar.isHidden || bar.frame.minY >= window.bounds.maxY - 1 || bar.alpha == 0,
                      "the tab bar must be hidden (or slid off screen) inside a pushed chat")
    }

    // MARK: - The Coordinator root keeps its tab bar (mission #3784)

    /// The Coordinator tab's root is a chat, and the tab bar is the only way
    /// out of it (spec §3).
    func test_coordinatorRoot_showsTheTabBar() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        try assertTabBarShowing("at the Coordinator root")
    }

    /// A notification tap or a conversation pill for the Coordinator while a
    /// chat is open in Conversations: the app switches tab with the bar
    /// hidden, which a person never can.
    func test_coordinatorRoot_showsTheTabBar_openedFromAPushedChat() throws {
        let nav = coordinatorNavigation()
        nav.chatPath = ["!r:s"]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the pushed chat")
        nav.openChat(Self.coordinator)
        XCTAssertEqual(nav.tab, .coordinator)
        try assertTabBarShowing("after the pushed chat handed over to the Coordinator")
    }

    /// "Open conversation" on a Decisions item that came from the Coordinator.
    func test_coordinatorRoot_showsTheTabBar_openedFromADecision() throws {
        let nav = coordinatorNavigation()
        nav.tab = .decisions
        nav.decisionsPath = [ItemRoute(id: "it_1")]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the item")
        nav.openConversation(fromDecisions: Self.coordinator)
        XCTAssertEqual(nav.tab, .coordinator)
        try assertTabBarShowing("after the item handed over to the Coordinator")
    }

    /// A link back to the Coordinator from a chat pushed on its own stack
    /// resets that stack to the root in one write.
    func test_coordinatorRoot_showsTheTabBar_afterItsStackResets() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        nav.coordinatorPath = ["!r:s", ItemRoute(id: "it_1").pathValue]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("two levels into the Coordinator's stack")
        nav.openConversationLink(Self.coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        try assertTabBarShowing("after the Coordinator's stack reset to its root")
    }

    /// The full-width swipe back writes the path itself.
    func test_coordinatorRoot_showsTheTabBar_afterBack() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        nav.coordinatorPath = ["!r:s"]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the chat pushed from the Coordinator")
        nav.setCoordinatorPath([])
        try assertTabBarShowing("back at the Coordinator root")
    }

    /// The Back button: UIKit pops the stack itself and the path follows.
    func test_coordinatorRoot_showsTheTabBar_afterTheBackButton() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        nav.setCoordinatorPath(["!r:s"])
        try assertTabBarHidden("inside the chat pushed from the Coordinator")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Coordinator root")
    }

    /// The bar comes back with the view update that uncovers the root, not
    /// with work queued behind it. The pop and the wait run inside one
    /// main-queue job: the main queue does not drain re-entrantly, so while
    /// that job turns the run loop nothing else queued on the main queue or
    /// the main actor gets a turn. A root that states nothing never gets
    /// its bar back here.
    func test_coordinatorRoot_showsTheTabBar_afterTheBackButton_withTheMainQueueHeld() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        nav.setCoordinatorPath(["!r:s"])
        try assertTabBarHidden("inside the chat pushed from the Coordinator")

        let held = HeldQueue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                DispatchQueue.main.async { MainActor.assumeIsolated { held.queuedWorkRan = true } }
                Task { @MainActor in held.queuedWorkRan = true }
                held.outcome = Result {
                    try self.popTheSelectedStack()
                    try self.assertTabBarShowing("back at the Coordinator root", timeout: 5)
                }
                XCTAssertFalse(held.queuedWorkRan, "the main queue must stay held for this test to mean anything")
            }
        }
        let end = Date().addingTimeInterval(30)
        while held.outcome == nil, Date() < end { settle(0.1) }
        try XCTUnwrap(held.outcome, "the held job never ran").get()
    }

    /// Dan's way out while it was stuck: push the mission page, go Back.
    func test_coordinatorRoot_showsTheTabBar_afterAMissionPageAndBack() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        nav.setCoordinatorPath([MissionRoute(id: "ms_1").pathValue])
        try assertTabBarHidden("inside the mission page")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Coordinator root")
        XCTAssertEqual(nav.coordinatorPath, [])
    }

    /// The same rule on the other tabs' roots.
    func test_conversationsRoot_showsTheTabBar_afterTheBackButton() throws {
        let nav = coordinatorNavigation()
        renderShellWithCoordinator(nav)
        nav.setChatPath(["!r:s"])
        try assertTabBarHidden("inside the pushed chat")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the conversation list")
        XCTAssertEqual(nav.chatPath, [])
    }

    func test_decisionsRoot_showsTheTabBar_afterTheBackButton() throws {
        let nav = coordinatorNavigation()
        nav.tab = .decisions
        renderShellWithCoordinator(nav)
        nav.pushDecision("it_1")
        try assertTabBarHidden("inside the item")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Decisions list")
        XCTAssertEqual(nav.decisionsPath, [])
    }

    func test_missionsRoot_showsTheTabBar_afterTheBackButton() throws {
        let nav = coordinatorNavigation()
        nav.tab = .missions
        renderShellWithCoordinator(nav)
        nav.pushMission("ms_1")
        try assertTabBarHidden("inside the mission page")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Missions list")
        XCTAssertEqual(nav.missionsPath, [])
    }

    /// The Coordinator's stack holds a pushed chat while Conversations shows
    /// another; opening the Coordinator resets its stack and switches tab
    /// in the same write.
    func test_coordinatorRoot_showsTheTabBar_afterItsStackResetsWithTheTabSwitch() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        nav.coordinatorPath = ["!r:s"]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the chat pushed from the Coordinator")
        nav.openChat("!other:s")
        XCTAssertEqual(nav.coordinatorPath, ["!r:s"])
        try assertTabBarHidden("inside the other chat, in Conversations")
        nav.openChat(Self.coordinator)
        XCTAssertEqual(nav.coordinatorPath, [])
        try assertTabBarShowing("after the Coordinator's stack reset with the tab switch")
    }

    /// The Memories pages are pushed on the Missions stack like any other
    /// page (spec §3: the bar shows only at the root of a tab).
    func test_memoriesPages_hideTheTabBar_andTheMissionsRootShowsItAgain() throws {
        let nav = coordinatorNavigation()
        nav.tab = .missions
        renderShellWithCoordinator(nav)
        try assertTabBarShowing("at the Missions root")
        nav.openMemories()
        try assertTabBarHidden("on the Memories list")
        nav.openMemory("avoid-eric")
        try assertTabBarHidden("on one memory")
        try popTheSelectedStack()
        try assertTabBarHidden("back on the Memories list")
        try popTheSelectedStack()
        try assertTabBarShowing("back at the Missions root")
        XCTAssertEqual(nav.missionsPath, [])
    }

    /// One rule for every page: the tab on screen and whether anything is
    /// pushed on it. Outside the shell a page falls back to its own value.
    func test_tabBarRule_followsTheSelectedTab() {
        XCTAssertEqual(TabBarRule.visibility(selectedTabIsAtRoot: true, otherwise: .hidden), .visible)
        XCTAssertEqual(TabBarRule.visibility(selectedTabIsAtRoot: false, otherwise: .visible), .hidden)
        XCTAssertEqual(TabBarRule.visibility(selectedTabIsAtRoot: nil, otherwise: .hidden), .hidden)
        XCTAssertEqual(TabBarRule.visibility(selectedTabIsAtRoot: nil, otherwise: .visible), .visible)
    }

    // MARK: - A push on a tab that is not on screen (mission #3784, second report)

    /// A session the Coordinator starts auto-opens in Conversations while
    /// the Coordinator tab stays on screen (`autoOpenChat`). That chat hides
    /// the tab bar for ITS stack; the bar on screen belongs to the
    /// Coordinator root and must stay.
    func test_coordinatorRoot_keepsTheTabBar_whenAChatAutoOpensInConversations() throws {
        let nav = coordinatorNavigation()
        renderShellWithCoordinator(nav)
        XCTAssertEqual(nav.tab, .conversations, "Conversations mounts first, as on a launch")
        try assertTabBarShowing("at the Conversations root")
        nav.tab = .coordinator
        try assertTabBarShowing("at the Coordinator root")
        nav.autoOpenChat("!new:s")
        XCTAssertEqual(nav.tab, .coordinator)
        XCTAssertEqual(nav.chatPath, ["!new:s"])
        try assertTabBarStaysShowing("after a chat auto-opened in Conversations, behind the Coordinator")
    }

    /// The same, with Conversations never visited.
    func test_coordinatorRoot_keepsTheTabBar_whenAChatAutoOpensInConversations_neverVisited() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        try assertTabBarShowing("at the Coordinator root")
        nav.autoOpenChat("!new:s")
        XCTAssertEqual(nav.chatPath, ["!new:s"])
        try assertTabBarStaysShowing("after a chat auto-opened in Conversations, never visited")
    }

    /// A second auto-open replaces the chat already behind the Coordinator.
    func test_coordinatorRoot_keepsTheTabBar_whenTheAutoOpenedChatIsReplaced() throws {
        let nav = coordinatorNavigation()
        nav.chatPath = ["!r:s"]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the pushed chat")
        nav.openChat(Self.coordinator)
        try assertTabBarShowing("at the Coordinator root")
        nav.autoOpenChat("!new:s")
        XCTAssertEqual(nav.chatPath, ["!new:s"])
        try assertTabBarStaysShowing("after the chat behind the Coordinator was replaced")
    }

    /// Any root, any other stack: a push on Decisions while Missions shows.
    func test_missionsRoot_keepsTheTabBar_whenAnItemIsPushedInDecisions() throws {
        let nav = coordinatorNavigation()
        nav.tab = .decisions
        renderShellWithCoordinator(nav)
        try assertTabBarShowing("at the Decisions root")
        nav.tab = .missions
        try assertTabBarShowing("at the Missions root")
        nav.push(ItemRoute(id: "it_1").pathValue, on: .decisions)
        XCTAssertEqual(nav.decisionsPath, [ItemRoute(id: "it_1")])
        try assertTabBarStaysShowing("after an item was pushed in Decisions, behind Missions")
    }

    /// The other way round: a stack that empties behind a pushed chat
    /// (a chat cut from the Coordinator's stack, a new Coordinator) must
    /// not bring the bar up over that chat.
    func test_pushedChat_keepsTheTabBarHidden_whenTheCoordinatorStackEmptiesBehindIt() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        nav.coordinatorPath = ["!r:s"]
        renderShellWithCoordinator(nav)
        try assertTabBarHidden("inside the chat pushed from the Coordinator")
        nav.openChat("!other:s")
        XCTAssertEqual(nav.tab, .conversations)
        try assertTabBarHidden("inside the other chat, in Conversations")
        nav.coordinatorPath = []
        try assertTabBarStaysHidden("after the Coordinator's stack emptied behind the pushed chat")
    }

    /// SCRATCH: is a pop asked for mid-push dropped? Pops at once after the
    /// path write, without waiting for the transition.
    func test_SCRATCH_popMidPush() throws {
        let nav = coordinatorNavigation()
        nav.tab = .coordinator
        renderShellWithCoordinator(nav)
        let tabs = try XCTUnwrap(find(UITabBarController.self, in: window.rootViewController))
        let stack = try XCTUnwrap(find(UINavigationController.self, in: tabs.selectedViewController))
        nav.setCoordinatorPath([MissionRoute(id: "ms_1").pathValue])
        var turns = 0
        while stack.viewControllers.count < 2, turns < 200 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            turns += 1
        }
        print("POPMID after \(turns) turns: count=\(stack.viewControllers.count) transition=\(stack.transitionCoordinator != nil) hidden=\(try tabBarIsHidden().hidden)")
        let popped = stack.popViewController(animated: true)
        print("POPMID popViewController returned \(popped == nil ? "nil" : "a controller")")
        for i in 0..<40 {
            settle(0.25)
            print("POPMID t=\(Double(i + 1) * 0.25) count=\(stack.viewControllers.count) transition=\(stack.transitionCoordinator != nil) path=\(nav.coordinatorPath) hidden=\(try tabBarIsHidden().hidden)")
        }
        XCTAssertEqual(nav.coordinatorPath, [], "SCRATCH: expected to fail if the pop was dropped")
    }

    // MARK: - helpers

    /// What the held-main-queue test's job leaves behind for the test.
    private final class HeldQueue {
        var queuedWorkRan = false
        var outcome: Result<Void, Error>?
    }

    private static let coordinator = "!coord:s"

    private func coordinatorNavigation() -> AppShellNavigation {
        let nav = AppShellNavigation()
        // Set before any path: a new Coordinator resets its tab's stack.
        nav.coordinatorConvoID = Self.coordinator
        return nav
    }

    /// The shell with a Coordinator conversation set, so the Coordinator
    /// tab's root is its chat rather than the setup view.
    private func renderShellWithCoordinator(_ nav: AppShellNavigation) {
        let key = CoordinatorSetting.defaultsKey(for: "@a:s")
        UserDefaults.standard.set(Self.coordinator, forKey: key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        renderInWindow(makeShell(navigation: nav))
        settle()
    }

    /// Turns the run loop for `seconds`, and for at least a few turns
    /// however long one of them stalls.
    private func settle(_ seconds: TimeInterval = 1) {
        let end = Date().addingTimeInterval(seconds)
        var turns = 0
        while Date() < end || turns < 5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            turns += 1
        }
    }

    /// What the Back button does: UIKit pops the selected tab's stack.
    private func popTheSelectedStack() throws {
        let tabs = try XCTUnwrap(find(UITabBarController.self, in: window.rootViewController))
        let stack = try XCTUnwrap(find(UINavigationController.self, in: tabs.selectedViewController))
        XCTAssertGreaterThan(stack.viewControllers.count, 1, "something must be pushed")
        stack.popViewController(animated: true)
    }

    private func find<T: UIViewController>(_ type: T.Type, in root: UIViewController?) -> T? {
        guard let root else { return nil }
        if let hit = root as? T { return hit }
        for child in root.children {
            if let hit = find(type, in: child) { return hit }
        }
        return nil
    }

    private func tabBarIsHidden() throws -> (hidden: Bool, state: String) {
        let bar = try XCTUnwrap(findTabBar(in: window))
        let hidden = bar.isHidden || bar.frame.minY >= window.bounds.maxY - 1 || bar.alpha == 0
        return (hidden, "isHidden=\(bar.isHidden) frame=\(bar.frame) alpha=\(bar.alpha)")
    }

    /// Waits for the bar to get there (a push or pop animates, and the
    /// runner stalls), then checks it stays.
    private func waitForTabBar(hidden: Bool, timeout: TimeInterval) throws -> (hidden: Bool, state: String) {
        let end = Date().addingTimeInterval(timeout)
        while try tabBarIsHidden().hidden != hidden, Date() < end {
            settle(0.1)
        }
        settle(0.5)
        return try tabBarIsHidden()
    }

    private func assertTabBarShowing(_ when: String, timeout: TimeInterval = 10,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let (hidden, state) = try waitForTabBar(hidden: false, timeout: timeout)
        XCTAssertFalse(hidden, "the tab bar must show \(when) (\(state))", file: file, line: line)
    }

    /// Samples the bar for `seconds`: every reading must match. Prints the
    /// readings, so a run is evidence either way.
    private func assertTabBarStays(hidden expected: Bool, _ when: String, for seconds: TimeInterval = 4,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let start = Date()
        var readings: [String] = []
        var wrongAt: [String] = []
        while Date().timeIntervalSince(start) < seconds {
            let (hidden, state) = try tabBarIsHidden()
            let stamp = String(format: "%.1fs", Date().timeIntervalSince(start))
            readings.append("\(stamp) hidden=\(hidden) \(state)")
            if hidden != expected { wrongAt.append(stamp) }
            settle(0.2)
        }
        print("TABBAR-TIMELINE [\(when)]\n" + readings.joined(separator: "\n"))
        XCTAssertTrue(wrongAt.isEmpty,
                      "the tab bar must stay \(expected ? "hidden" : "showing") \(when); "
                          + "\(expected ? "showing" : "hidden") at \(wrongAt.joined(separator: ", "))",
                      file: file, line: line)
    }

    private func assertTabBarStaysShowing(_ when: String, file: StaticString = #filePath,
                                          line: UInt = #line) throws {
        try assertTabBarStays(hidden: false, when, file: file, line: line)
    }

    private func assertTabBarStaysHidden(_ when: String, file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        try assertTabBarStays(hidden: true, when, file: file, line: line)
    }

    private func assertTabBarHidden(_ when: String, timeout: TimeInterval = 10,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let (hidden, state) = try waitForTabBar(hidden: true, timeout: timeout)
        XCTAssertTrue(hidden, "the tab bar must be hidden \(when) (\(state))", file: file, line: line)
    }

    @discardableResult
    func renderInWindow<V: View>(_ view: V) -> UIView {
        let hosting = UIHostingController(rootView: view)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        }
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        hosting.view.layoutIfNeeded()
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            hosting.view.layoutIfNeeded()
        }
        return hosting.view
    }

    func findTabBar(in root: UIView) -> UITabBar? {
        if let bar = root as? UITabBar { return bar }
        for sub in root.subviews {
            if let found = findTabBar(in: sub) { return found }
        }
        return nil
    }
}

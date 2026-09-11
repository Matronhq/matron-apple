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

    func test_shell_showsFourTabs_atTheRoot() throws {
        // Coordinator, Missions, Decisions, Conversations (Task 9) — the
        // Missions tab starts visible: `MissionsListViewModel.isSupported`
        // defaults `nil` (not yet known) until a refresh says otherwise,
        // and `nil` is treated as supported, same as Decisions.
        renderInWindow(makeShell(navigation: AppShellNavigation()))
        let bar = try XCTUnwrap(findTabBar(in: window), "TabView must bridge to a UITabBar")
        XCTAssertEqual(bar.items?.count, 4)
        XCTAssertFalse(bar.isHidden)
        XCTAssertLessThan(bar.frame.minY, window.bounds.maxY, "the bar is on screen at the root")
    }

    func test_shell_opensOnConversations() {
        let nav = AppShellNavigation()
        renderInWindow(makeShell(navigation: nav))
        XCTAssertEqual(nav.tab, .conversations)
    }

    /// Spec §3: the tab bar shows only at the root of each tab — a pushed
    /// chat carries `.toolbar(.hidden, for: .tabBar)`.
    func test_pushedChat_hidesTheTabBar() throws {
        let nav = AppShellNavigation()
        nav.chatPath = ["!r:s"]
        renderInWindow(makeShell(navigation: nav))
        let bar = try XCTUnwrap(findTabBar(in: window))
        XCTAssertTrue(bar.isHidden || bar.frame.minY >= window.bounds.maxY - 1 || bar.alpha == 0,
                      "the tab bar must be hidden (or slid off screen) inside a pushed chat")
    }

    // MARK: - helpers

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

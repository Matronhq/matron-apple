#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac

/// The Mac mission page's two views at a wide (two-column) and a narrow
/// (one-column) detail width, light and dark. The top bar is included so
/// the switcher shows which view is chosen.
@MainActor
final class MacMissionPageSnapshotTests: XCTestCase {
    private typealias F = MacMissionPageFixtures
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "MacMissionPageSnapshotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func page(_ mode: MacMissionPageMode, width: CGFloat, height: CGFloat) -> some View {
        defaults.set(mode.rawValue, forKey: MacMissionPage.modeKey)
        return VStack(spacing: 0) {
            // `F.mission`/`F.project` so the breadcrumb pins "Projects ›
            // Promo launch › #3778" (mockup 03), and a non-nil `onMove` so
            // the header's Move menu is drawn (never `canMove: false`'s
            // nil, which this fixture never exercises).
            MacMissionPageTopBar(mission: F.mission, project: F.project, backConvoID: nil, onBack: { _ in },
                                 onShowDashboard: {}, onShowProject: { _ in }, store: defaults)
            Divider()
            MacMissionPageContentHost(model: F.model(), actions: .init(onMove: { _ in }), store: defaults)
        }
        .frame(width: width, height: height)
        .environment(\.macMissionPageClock, F.now)
    }

    func testOverviewWide() {
        assertVariants(of: page(.overview, width: 1_440, height: 1_120), named: "mission-page-overview-1440")
    }

    func testOverviewNarrow() {
        assertVariants(of: page(.overview, width: 800, height: 1_480), named: "mission-page-overview-800")
    }

    func testBoardWide() {
        assertVariants(of: page(.board, width: 1_440, height: 1_000), named: "mission-page-board-1440")
    }

    func testBoardNarrow() {
        assertVariants(of: page(.board, width: 800, height: 1_200), named: "mission-page-board-800")
    }
}
#endif

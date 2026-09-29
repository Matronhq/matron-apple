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
            MacMissionPageTopBar(backConvoID: nil, onBack: { _ in }, onShowDashboard: {}, store: defaults)
            Divider()
            MacMissionPageContentHost(model: F.model(), now: F.now, actions: .init(), store: defaults)
        }
        .frame(width: width, height: height)
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

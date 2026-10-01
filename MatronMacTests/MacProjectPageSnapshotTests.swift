#if os(macOS)
import XCTest
import SwiftUI
@testable import MatronMac
import MatronModels

@MainActor
final class MacProjectPageSnapshotTests: XCTestCase {
    private typealias F = MacProjectPageFixtures

    func testOtherOpenItemsNeverGoesNegative() {
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(F.page), 40)
        var none = F.page
        none.project = Project(id: "pj_1", num: 1, title: "P", openItems: 1)
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(none), 0)
    }

    private func page(width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: F.page, actions: .init())
            Divider()
            MacProjectPageContent(page: F.page, actions: .init())
        }
        .frame(width: width, height: height)
        .environment(\.macMissionPageClock, F.now)
    }

    func testProjectPageWide() {
        assertVariants(of: page(width: 1_440, height: 1_000), named: "project-page-1440")
    }

    func testProjectPageNarrow() {
        assertVariants(of: page(width: 800, height: 1_500), named: "project-page-800")
    }
}
#endif

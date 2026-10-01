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
        none.openItems = none.needsYou
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(none), 0)
    }

    func testOtherOpenItemsCountsTheLocalRowsWhenTheJournalLags() {
        var lagging = F.page
        lagging.project = Project(id: "pj_1", num: 1, title: "P", openItems: 4)
        XCTAssertEqual(MacProjectPageContent.otherOpenItems(lagging), 10, "never fewer than the rows listed")
    }

    func testAwaitingLabels() {
        XCTAssertEqual(MacProjectItemRow.awaitingLabel(.agent), "agent")
        XCTAssertEqual(MacProjectItemRow.awaitingLabel(.user), "you")
        XCTAssertNil(MacProjectItemRow.awaitingLabel(nil))
    }

    private func page(width: CGFloat, height: CGFloat, selectedBox: String? = nil,
                      showsAllItems: Bool = false) -> some View {
        VStack(spacing: 0) {
            MacProjectPageTopBar(page: F.page, actions: .init())
            Divider()
            MacProjectPageContent(page: F.page, actions: .init(), selectedBox: selectedBox, showsAllItems: showsAllItems)
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

    /// A box clicked (greg), and every other open item unfolded.
    func testProjectPageFilteredAndExpanded() {
        assertVariants(of: page(width: 1_440, height: 1_300, selectedBox: "greg", showsAllItems: true),
                       named: "project-page-1440-filtered")
    }
}
#endif

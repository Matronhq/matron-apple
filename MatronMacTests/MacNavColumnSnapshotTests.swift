#if os(macOS)
import SwiftUI
import XCTest
@testable import MatronMac

/// App shell (spec §5): the big-icon navigation column to the left of the
/// conversations list. Pure view, so the baselines need no VM.
final class MacNavColumnSnapshotTests: XCTestCase {
    @MainActor
    func testBadge() {
        let view = MacNavColumn(selection: .constant(.decisions), badges: [.decisions: 4])
            .frame(height: 320)
        assertVariants(of: view, named: "MacNavColumn_badge")
    }

    @MainActor
    func testNoBadge() {
        let view = MacNavColumn(selection: .constant(.conversations), badges: [:])
            .frame(height: 320)
        assertVariants(of: view, named: "MacNavColumn_noBadge")
    }

    func testEntriesInBarOrder() {
        XCTAssertEqual(MacNav.allCases, [.coordinator, .missions, .decisions, .conversations])
        XCTAssertEqual(MacNav.decisions.symbol, "checkmark.circle")
        XCTAssertEqual(MacNavColumn.width, 72)
    }
}
#endif

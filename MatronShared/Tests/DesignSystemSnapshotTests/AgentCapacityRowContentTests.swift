import XCTest
import SwiftUI
@testable import MatronDesignSystem
import MatronModels

final class AgentCapacityRowContentTests: XCTestCase {
    func test_sessionsText_pluralisesAndNamesZero() {
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(0), "No active sessions")
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(1), "1 active session")
        XCTAssertEqual(AgentCapacityRowContent.sessionsText(2), "2 active sessions")
    }

    /// The chooser rows tint percentages with the same helper the /usage
    /// bars use — one threshold table, not two (green < 50, orange < 80,
    /// red >= 80 is pinned by `UsageMetersFormatTests`).
    func test_percentTint_reusesUsageMetersThresholds() {
        XCTAssertEqual(AgentCapacityRowContent.percentColor(49), UsageMetersFormat.barColor(percent: 49))
        XCTAssertEqual(AgentCapacityRowContent.percentColor(50), UsageMetersFormat.barColor(percent: 50))
        XCTAssertEqual(AgentCapacityRowContent.percentColor(80), UsageMetersFormat.barColor(percent: 80))
    }
}

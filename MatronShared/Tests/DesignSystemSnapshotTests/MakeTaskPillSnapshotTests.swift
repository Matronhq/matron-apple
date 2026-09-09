import SwiftUI
import XCTest
@testable import MatronDesignSystem

/// Visual baseline for the floating "Make task" pill (Task 12) — the
/// composer overlay that files the current draft as a tracker task
/// instead of sending it.
final class MakeTaskPillSnapshotTests: XCTestCase {
    func testPill() {
        assertVariants(of: MakeTaskPill {}.padding(20).background(Color.gray.opacity(0.2)), named: "MakeTaskPill")
    }
}

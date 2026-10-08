import XCTest
import SwiftUI
import SnapshotTesting
@testable import MatronDesignSystem

/// Pins the visibility rule and visual family for the top-trailing chat
/// overlay stack (Stop pill above, "jump to my last message" pill below —
/// or the jump pill alone in Stop's place when no turn is running).
final class ChatTopTrailingControlsTests: XCTestCase {
    func test_showsJump_rule() {
        XCTAssertTrue(ChatTopTrailingControls.showsJump(isFollowingTail: false, isTasksPage: false))
        XCTAssertFalse(ChatTopTrailingControls.showsJump(isFollowingTail: true, isTasksPage: false))
        XCTAssertFalse(ChatTopTrailingControls.showsJump(isFollowingTail: false, isTasksPage: true))
        XCTAssertFalse(ChatTopTrailingControls.showsJump(isFollowingTail: true, isTasksPage: true))
    }

    private func hosted(showsStop: Bool, showsJump: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.gray.opacity(0.2)
            ChatTopTrailingControls(
                showsStop: showsStop,
                showsJump: showsJump,
                onStop: {},
                onJump: {}
            )
        }
        .frame(width: 120, height: 120, alignment: .topTrailing)
    }

    func test_stopOnly() {
        assertVariants(of: hosted(showsStop: true, showsJump: false), named: "stop_only")
    }

    func test_jumpOnly() {
        assertVariants(of: hosted(showsStop: false, showsJump: true), named: "jump_only")
    }

    func test_both() {
        assertVariants(of: hosted(showsStop: true, showsJump: true), named: "both")
    }
}

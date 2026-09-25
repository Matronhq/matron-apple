import XCTest
@testable import Matron

/// Tracker #3141: the chat keeps its composer above the keyboard from
/// UIKit's `keyboardLayoutGuide`, not SwiftUI's keyboard safe area, which
/// goes out of sync when a chat comes back on screen (see
/// `ChatKeyboardAvoidance`).
final class ChatKeyboardAvoidanceTests: XCTestCase {
    /// Keyboard top at y=539 over a chat whose bottom edge is y=791 (the
    /// tab bar's top on the Coordinator tab): the composer lifts 252pt.
    func test_overlap_isHowFarTheKeyboardReachesAboveTheChatsBottom() {
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(viewHeight: 791, keyboardTop: 539), 252)
    }

    /// No keyboard: the guide's top sits at or below the view's bottom.
    func test_overlap_isZeroWithoutAKeyboard() {
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(viewHeight: 840, keyboardTop: 840), 0)
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(viewHeight: 791, keyboardTop: 874), 0,
                       "a guide below the view (tab bar, home indicator) is no overlap")
    }

    /// The keyboard's own show/hide runs inside a UIKit animation: follow it.
    /// An interactive dismissal moves the guide frame by frame with no
    /// animation: track the finger exactly.
    func test_animation_followsTheKeyboardsAnimation_andNotAnInteractiveDrag() {
        XCTAssertNotNil(ChatKeyboardAvoidance.animation(forInheritedDuration: 0.25))
        XCTAssertNil(ChatKeyboardAvoidance.animation(forInheritedDuration: 0))
    }

    /// Source pin: the chat opts out of SwiftUI's keyboard safe area and
    /// pads by the guide instead — the two together, on the pager.
    func test_chatView_padsByTheGuide_insteadOfTheKeyboardSafeArea() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Matron/Features/Chat/ChatView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains(".chatKeyboardAvoidance()"))
    }
}

import XCTest
@testable import Matron

/// The chat keeps its composer above the keyboard from the keyboard's
/// frame notifications and UIKit's `keyboardLayoutGuide`, not SwiftUI's
/// keyboard safe area, which goes out of sync when a chat comes back on
/// screen (see `ChatKeyboardAvoidance`).
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

    private let screen = CGRect(x: 0, y: 0, width: 402, height: 874)
    /// A chat that stops at the home indicator.
    private let chat = CGRect(x: 0, y: 116, width: 402, height: 724)

    /// A docked keyboard at y=546 reaches 294pt above the chat's bottom.
    func test_notifiedOverlap_isHowFarADockedKeyboardReachesAboveTheChatsBottom() {
        let keyboard = CGRect(x: 0, y: 546, width: 402, height: 328)
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(keyboardFrame: keyboard, viewFrame: chat, screenBounds: screen), 294)
    }

    /// A hiding keyboard's end frame sits below the screen; a hide is
    /// recorded as `.zero`. Neither covers the chat.
    func test_notifiedOverlap_isZeroForAHiddenKeyboard() {
        let offScreen = CGRect(x: 0, y: 874, width: 402, height: 328)
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(keyboardFrame: offScreen, viewFrame: chat, screenBounds: screen), 0)
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(keyboardFrame: .zero, viewFrame: chat, screenBounds: screen), 0)
    }

    /// iPad's floating keyboard sits mid-screen: no overlap, as with the guide.
    func test_notifiedOverlap_isZeroForAKeyboardNotDockedAtTheBottom() {
        let iPad = CGRect(x: 0, y: 0, width: 1032, height: 1376)
        let floating = CGRect(x: 300, y: 700, width: 320, height: 260)
        XCTAssertEqual(ChatKeyboardAvoidance.overlap(keyboardFrame: floating,
                                                     viewFrame: CGRect(x: 0, y: 80, width: 1032, height: 1276),
                                                     screenBounds: iPad), 0)
    }

    /// The reported fault: the guide stops tracking after the app comes
    /// back from the background. Stuck at "no keyboard" with one showing,
    /// or stuck raised with none, it never moves, so the notification wins.
    func test_layoutOverlap_aStuckGuideNeverOverridesTheNotification() {
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 0, guideMoved: false, notified: 294, animating: false), 294)
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 294, guideMoved: false, notified: 0, animating: false), 0)
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 294, guideMoved: true, notified: 0, animating: false), 0,
                       "a raised guide never lifts the composer above a hidden keyboard")
    }

    /// Around a trip to the background the guide can jump once on its way
    /// to being stuck: with the guide not trusted, that jump is ignored.
    func test_layoutOverlap_ignoresAGuideJumpAroundTheBackground() {
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 0, guideMoved: true, notified: 294,
                                                           animating: false, trustsGuide: false), 294)
    }

    /// An interactive dismissal moves the guide frame by frame with no
    /// notifications: follow it down.
    func test_layoutOverlap_followsAMovingGuideDuringAnInteractiveDismissal() {
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 180, guideMoved: true, notified: 294, animating: false), 180)
    }

    /// The keyboard's own show/hide and rotations run inside an animation:
    /// the notification has the answer.
    func test_layoutOverlap_usesTheNotificationInsideAnAnimation() {
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 0, guideMoved: true, notified: 294, animating: true), 294)
    }

    /// Before the app has seen any keyboard notification, the guide is all
    /// there is.
    func test_layoutOverlap_fallsBackToTheGuideBeforeAnyNotification() {
        XCTAssertEqual(ChatKeyboardAvoidance.layoutOverlap(guide: 120, guideMoved: false, notified: nil, animating: false), 120)
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

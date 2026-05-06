#if os(macOS)
import XCTest
@testable import MatronMac

/// Pins `MacNotificationHandler.handleTap` — the testable surface that
/// the `userNotificationCenter(_:didReceive:)` delegate method extracts
/// out so unit tests don't have to construct a `UNNotificationResponse`
/// (which has no public init).
@MainActor
final class MacNotificationHandlerTests: XCTestCase {
    func test_handleTap_postsMatronOpenRoom_carryingRoomID() async {
        let handler = MacNotificationHandler()
        let exp = expectation(description: "matronOpenRoom posted")

        let token = NotificationCenter.default.addObserver(
            forName: .matronOpenRoom, object: nil, queue: nil
        ) { note in
            // Pull room ID via the public key constant — same lookup
            // path `MacChatListView.onReceive` uses, so a refactor of
            // the userInfo schema would break both call sites and
            // this test together.
            if let roomID = note.userInfo?[MacNotificationHandler.roomIDKey] as? String,
               roomID == "!r:s.example" {
                exp.fulfill()
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        handler.handleTap(userInfo: [
            "room_id": "!r:s.example",
            "event_id": "$evt"
        ])

        await fulfillment(of: [exp], timeout: 1.0)
    }

    func test_handleTap_missingRoomID_isHarmless() async {
        // Tapping a notification whose userInfo doesn't carry a
        // `room_id` (corrupt payload, or a system notification we
        // forwarded by accident) shouldn't post anything. Pin the
        // contract so a future refactor that "just-in-cases" a
        // default doesn't silently land a wrong-room navigation.
        let handler = MacNotificationHandler()
        var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: .matronOpenRoom, object: nil, queue: nil
        ) { _ in posted = true }
        defer { NotificationCenter.default.removeObserver(token) }

        handler.handleTap(userInfo: [:])
        // Yield once so any in-flight post would land before the assert.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(posted)
    }
}
#endif

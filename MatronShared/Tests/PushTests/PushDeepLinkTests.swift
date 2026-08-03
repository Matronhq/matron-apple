import XCTest
@testable import MatronPush

/// Pins the notification-tap deep-link resolution against the payload the
/// push relay actually sends. The relay (`matron-journal` `src/push.js`)
/// carries the conversation id ONLY as `aps.thread-id` — there is no
/// top-level `room_id` custom key — so the resolver must fall back to the
/// aps dictionary or every tap lands on the chat list instead of the chat.
final class PushDeepLinkTests: XCTestCase {

    /// The exact shape the relay sends today: alert + thread-id, no
    /// custom keys. This is the case that was broken in the field.
    func test_relayPayload_resolvesFromApsThreadID() {
        let userInfo: [AnyHashable: Any] = [
            "aps": [
                "alert": ["title": "Some chat", "body": "Turn finished"],
                "thread-id": "convo-abc123",
            ],
        ]
        XCTAssertEqual(PushDeepLink.roomID(fromUserInfo: userInfo), "convo-abc123")
    }

    /// Explicit `room_id` (the NSE-rewrite / future-relay path) wins over
    /// the aps fallback.
    func test_explicitRoomID_winsOverThreadID() {
        let userInfo: [AnyHashable: Any] = [
            "room_id": "convo-explicit",
            "aps": ["thread-id": "convo-thread"],
        ]
        XCTAssertEqual(PushDeepLink.roomID(fromUserInfo: userInfo), "convo-explicit")
    }

    func test_explicitRoomIDAlone_resolves() {
        XCTAssertEqual(PushDeepLink.roomID(fromUserInfo: ["room_id": "convo-x"]), "convo-x")
    }

    /// Empty strings are "absent", not a navigation target — an empty
    /// path element would push a destination for a room that can't exist.
    func test_emptyStrings_resolveNil() {
        XCTAssertNil(PushDeepLink.roomID(fromUserInfo: ["room_id": ""]))
        XCTAssertNil(PushDeepLink.roomID(fromUserInfo: ["aps": ["thread-id": ""]]))
    }

    /// A non-string `room_id` must not mask a usable thread-id.
    func test_nonStringRoomID_fallsBackToThreadID() {
        let userInfo: [AnyHashable: Any] = [
            "room_id": 42,
            "aps": ["thread-id": "convo-fallback"],
        ]
        XCTAssertEqual(PushDeepLink.roomID(fromUserInfo: userInfo), "convo-fallback")
    }

    /// Background wakes (`content-available` only) and malformed payloads
    /// resolve nil — the tap opens the app without navigating.
    func test_payloadWithoutAnyID_resolvesNil() {
        XCTAssertNil(PushDeepLink.roomID(fromUserInfo: [:]))
        XCTAssertNil(PushDeepLink.roomID(fromUserInfo: ["aps": ["content-available": 1]]))
        XCTAssertNil(PushDeepLink.roomID(fromUserInfo: ["aps": "not-a-dict"]))
    }
}

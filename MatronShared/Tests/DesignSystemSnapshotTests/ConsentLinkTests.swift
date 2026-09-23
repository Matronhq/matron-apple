import XCTest
import MatronModels
@testable import MatronDesignSystem

/// The journal files a consent ask as a `question` item whose one link is
/// `matron://consent/spawn/<request_id>` (or `matron://consent/chat/<room>/<device>`).
/// That link is how an item is recognised as a consent ask, so — like
/// `MatronItemLink.itemNumber` — the parser accepts only the canonical form.
final class ConsentLinkTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "about:blank")!
        }
        return url
    }

    func test_parse_acceptsSpawnAndChatForms() {
        XCTAssertEqual(ConsentLink.parse(url("matron://consent/spawn/spawn-1")), .spawn(requestID: "spawn-1"))
        XCTAssertEqual(ConsentLink.parse(url("matron://consent/spawn/8f1c2a3b-4d5e")), .spawn(requestID: "8f1c2a3b-4d5e"))
        XCTAssertEqual(ConsentLink.parse(url("MATRON://CONSENT/spawn/abc")), .spawn(requestID: "abc"),
                       "scheme and host are case-insensitive; the id is not")
        XCTAssertEqual(ConsentLink.parse(url("matron://consent/chat/room-9/42")), .chat(roomID: "room-9", deviceID: 42))
        XCTAssertEqual(ConsentLink.parse("matron://consent/spawn/x"), .spawn(requestID: "x"), "the string form parses too")
    }

    func test_parse_rejectsEverythingElse() {
        let rejected = [
            "matron://consent/spawn",              // no id
            "matron://consent/spawn/",             // empty id
            "matron://consent/spawn/a/b",          // extra segment
            "matron://consent/spawn/a?x=1",        // query
            "matron://consent/spawn/a#frag",       // fragment
            "matron://consent/SPAWN/a",            // kind is case-sensitive, as the journal writes it
            "matron://consent/plan/a",             // unknown kind
            "matron://consent/chat/room",          // chat needs a device id
            "matron://consent/chat/room/0",        // device ids are positive
            "matron://consent/chat/room/abc",      // and numeric
            "matron://consent/chat/room/4/extra",
            "matron://item/65",
            "matron://consent",
            "https://consent/spawn/a",
            "not a link",
        ]
        for string in rejected {
            XCTAssertNil(ConsentLink.parse(string), "\(string) must not parse as a consent link")
        }
    }

    func test_trackerItem_findsItsSpawnConsentLink() {
        let item = TrackerItem(id: "it_1", num: 1, kind: .question, title: "Approve spawn on dev-2 — ci triage",
                               labels: ["consent"],
                               links: [TrackerLink(url: "https://example.com/context", title: "Context"),
                                       TrackerLink(url: "matron://consent/spawn/spawn-1", title: "Spawn request spawn-1")],
                               originConvoID: "c1")
        XCTAssertEqual(item.consentLink, .spawn(requestID: "spawn-1"))
        XCTAssertEqual(item.spawnConsentRequestID, "spawn-1")
        XCTAssertTrue(item.isConsentAsk)

        let chat = TrackerItem(id: "it_2", num: 2, kind: .question, title: "greg asks to chat with henry",
                               links: [TrackerLink(url: "matron://consent/chat/room-1/7")], originConvoID: "room-1")
        XCTAssertEqual(chat.consentLink, .chat(roomID: "room-1", deviceID: 7))
        XCTAssertNil(chat.spawnConsentRequestID, "a chat ask is a consent ask but not a spawn one")
        XCTAssertTrue(chat.isConsentAsk)

        let plain = TrackerItem(id: "it_3", num: 3, kind: .question, title: "Which auth library?",
                                labels: ["consent"], links: [TrackerLink(url: "https://github.com/x/y/issues/9")], originConvoID: "c1")
        XCTAssertNil(plain.consentLink, "the label alone does not make an item a consent ask; the link does")
        XCTAssertFalse(plain.isConsentAsk)
    }

    // MARK: - Link policy

    /// A consent chip in item detail opens in-app (the conversation holding
    /// the card, or the room) — never the OS, which has no handler for the
    /// scheme — and, unlike other unknown `matron://` URLs, is not swallowed.
    func test_action_routesConsentLinksInApp() {
        XCTAssertEqual(MatronItemLink.action(for: url("matron://consent/spawn/spawn-1")),
                       .openConsent(.spawn(requestID: "spawn-1")))
        XCTAssertEqual(MatronItemLink.action(for: url("matron://consent/chat/room-1/7")),
                       .openConsent(.chat(roomID: "room-1", deviceID: 7)))
        XCTAssertEqual(MatronItemLink.action(for: url("matron://consent/spawn/a/b")), .swallow,
                       "a malformed consent link is still a matron URL: swallowed, never handed to the OS")
    }
}

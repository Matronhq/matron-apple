import XCTest
@testable import MatronJournal

/// Pinned desk chats (journal "Pinned desk chats"): the pin model, the
/// `/pins` routes and the live `pins` frame.
final class ConvoPinsTests: XCTestCase {
    private func makeStubbedAPI(status: Int, body: [String: Any]) -> JournalAPI {
        ItemsStubURLProtocol.status = status
        ItemsStubURLProtocol.body = try! JSONSerialization.data(withJSONObject: body)
        ItemsStubURLProtocol.lastRequest = nil
        ItemsStubURLProtocol.lastBody = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ItemsStubURLProtocol.self]
        return JournalAPI(serverURL: URL(string: "https://chat.example.com")!,
                          urlSession: URLSession(configuration: config), token: "t")
    }

    private let listBody: [String: Any] = [
        "limit": 5,
        "pins": [
            ["convo_id": "c2", "label": "Docs review", "emoji": "", "position": 1, "device_id": 4,
             "created_at": 1, "updated_at": 1],
            ["convo_id": "c1", "label": "Inbox triage", "emoji": "📮", "position": 0, "device_id": 7,
             "successor": ["convo_id": "c9", "title": "[ab] New", "created_at": 1_800_000_000_000],
             "created_at": 1, "updated_at": 1],
            ["convo_id": "c3", "label": "Gone", "emoji": "", "position": 2, "missing": true,
             "created_at": 1, "updated_at": 1],
        ],
    ]

    private func sentBody() throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: XCTUnwrap(ItemsStubURLProtocol.lastBody)) as? [String: Any]
    }

    // MARK: - Model

    func testDecodeSortsByPositionAndKeepsEveryField() throws {
        let list = try XCTUnwrap(ConvoPinList.decode(listBody))
        XCTAssertEqual(list.pins.map(\.convoID), ["c1", "c2", "c3"])
        XCTAssertEqual(list.limit, 5)
        let support = list.pins[0]
        XCTAssertEqual(support.label, "Inbox triage")
        XCTAssertEqual(support.emoji, "📮")
        XCTAssertEqual(support.deviceID, 7)
        XCTAssertEqual(support.successor?.convoID, "c9")
        XCTAssertEqual(support.successor?.title, "[ab] New")
        XCTAssertEqual(support.successor?.createdAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(support.missing)
        XCTAssertTrue(list.pins[2].missing)
        XCTAssertNil(list.pins[2].deviceID)
    }

    func testDecodeDropsMalformedAndRepeatedRows() {
        let pins = ConvoPin.decodeList([
            ["convo_id": "a", "label": "A", "position": 0],
            ["convo_id": "a", "label": "Again", "position": 1],
            ["convo_id": "", "label": "No id"],
            ["convo_id": "b", "label": "   "],
            ["convo_id": "c"],
            "junk",
        ])
        XCTAssertEqual(pins?.map(\.convoID), ["a"])
        XCTAssertNil(ConvoPin.decodeList("not an array"), "a body with no pin array is not an empty list")
    }

    func testLimitDefaultsWhenMissingOrZero() {
        XCTAssertEqual(ConvoPinList.decode(["pins": []])?.limit, ConvoPin.defaultLimit)
        XCTAssertEqual(ConvoPinList.decode(["pins": [], "limit": 0])?.limit, ConvoPin.defaultLimit)
        XCTAssertNil(ConvoPinList.decode(["limit": 5]))
    }

    func testGlyphIsTheEmojiElseTheFirstLetterUpperCased() {
        XCTAssertEqual(ConvoPin(convoID: "a", label: "support", emoji: "📮").glyph, "📮")
        XCTAssertEqual(ConvoPin(convoID: "a", label: "support", emoji: "").glyph, "S")
        XCTAssertEqual(ConvoPin(convoID: "a", label: "  mail", emoji: "  ").glyph, "M")
        XCTAssertEqual(ConvoPin(convoID: "a", label: "élan").glyph, "É")
    }

    func testClampLabelIsOneTrimmedLineOfAtMost24CodePoints() {
        XCTAssertEqual(ConvoPin.clampLabel("  Inbox\n triage  "), "Inbox triage")
        XCTAssertEqual(ConvoPin.clampLabel(String(repeating: "x", count: 30)).count, 24)
        XCTAssertEqual(ConvoPin.clampLabel("abcdefghijklmnopqrstuvw yz"), "abcdefghijklmnopqrstuvw",
                       "a cut that ends on a space is trimmed")
        XCTAssertEqual(ConvoPin.clampLabel(String(repeating: "é", count: 30)).unicodeScalars.count, 24)
        XCTAssertEqual(ConvoPin.clampLabel("   "), "")
    }

    func testClampEmojiDropsWhitespaceAndKeepsAShortToken() {
        XCTAssertEqual(ConvoPin.clampEmoji(" 📮 "), "📮")
        XCTAssertEqual(ConvoPin.clampEmoji("👩‍👩‍👧‍👦"), "👩‍👩‍👧‍👦", "a family emoji is 11 UTF-16 units")
        XCTAssertEqual(ConvoPin.clampEmoji("📮📮📮📮📮📮📮📮📮"), "📮", "past 16 units it keeps the first character")
        XCTAssertEqual(ConvoPin.clampEmoji(""), "")
    }

    func testMovedOrderSwapsNeighboursAndRefusesTheEdges() {
        let pins = ["a", "b", "c"].map { ConvoPin(convoID: $0, label: $0) }
        XCTAssertEqual(ConvoPin.movedOrder(pins, "b", up: true), ["b", "a", "c"])
        XCTAssertEqual(ConvoPin.movedOrder(pins, "b", up: false), ["a", "c", "b"])
        XCTAssertNil(ConvoPin.movedOrder(pins, "a", up: true))
        XCTAssertNil(ConvoPin.movedOrder(pins, "c", up: false))
        XCTAssertNil(ConvoPin.movedOrder(pins, "z", up: true))
    }

    // MARK: - Routes

    func testGetReadsTheList() async throws {
        let list = try await makeStubbedAPI(status: 200, body: listBody).pins()
        XCTAssertEqual(list.pins.count, 3)
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins") == true)
    }

    func testOldJournalGetIsNotFound() async {
        do {
            _ = try await makeStubbedAPI(status: 404, body: ["error": "not_found"]).pins()
            XCTFail("expected notFound")
        } catch {
            XCTAssertEqual(error as? JournalAPIError, .notFound)
        }
    }

    func testPinSendsLabelAndEmojiToTheConversationsRoute() async throws {
        _ = try await makeStubbedAPI(status: 200, body: listBody).setPin("c1", label: "Inbox triage", emoji: "📮")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins/c1") == true)
        let sent = try sentBody()
        XCTAssertEqual(sent?["label"] as? String, "Inbox triage")
        XCTAssertEqual(sent?["emoji"] as? String, "📮")
    }

    func testRenameSendsOnlyWhatChanged() async throws {
        _ = try await makeStubbedAPI(status: 200, body: listBody).setPin("c1", label: nil, emoji: "🛟")
        let sent = try sentBody()
        XCTAssertNil(sent?["label"])
        XCTAssertEqual(sent?["emoji"] as? String, "🛟")
    }

    func testReorderUnpinMoveAndDismissHitTheirRoutes() async throws {
        let api = makeStubbedAPI(status: 200, body: listBody)
        _ = try await api.reorderPins(["c2", "c1", "c3"])
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins") == true)
        XCTAssertEqual(try sentBody()?["order"] as? [String], ["c2", "c1", "c3"])

        _ = try await api.unpin("c1")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins/c1") == true)

        _ = try await api.movePin("c1", to: "c9")
        XCTAssertEqual(ItemsStubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins/c1/move") == true)
        XCTAssertEqual(try sentBody()?["to_convo_id"] as? String, "c9")

        _ = try await api.dismissPinSuccessor("c1", successorID: "c9")
        XCTAssertTrue(ItemsStubURLProtocol.lastRequest?.url?.absoluteString.hasSuffix("/pins/c1/dismiss") == true)
        XCTAssertEqual(try sentBody()?["successor_id"] as? String, "c9")
    }

    func testConflictsAndRefusalsKeepTheirMeaning() async {
        await assertThrows(.limit(5), status: 409, body: ["error": "conflict", "detail": "pin_limit", "limit": 5]) {
            try await $0.setPin("c4", label: "Four", emoji: nil)
        }
        await assertThrows(.alreadyPinned, status: 409, body: ["error": "conflict", "detail": "already_pinned"]) {
            try await $0.movePin("c1", to: "c2")
        }
        await assertThrows(.notFound, status: 404, body: ["error": "not_found"]) { try await $0.unpin("c8") }
        await assertThrows(.invalid(""), status: 400, body: ["error": "bad_request"]) {
            try await $0.setPin("c1", label: "", emoji: nil)
        }
    }

    func testRefusalsReadAsSentences() {
        XCTAssertEqual(ConvoPinError.limit(5).localizedDescription, "You can pin up to 5 chats.")
        XCTAssertEqual(ConvoPinError.alreadyPinned.localizedDescription, "That chat is already pinned.")
        XCTAssertEqual(ConvoPinError.notFound.localizedDescription, "That chat isn't pinned any more.")
    }

    private func assertThrows(_ expected: ConvoPinError, status: Int, body: [String: Any],
                              _ call: (JournalAPI) async throws -> ConvoPinList,
                              file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await call(makeStubbedAPI(status: status, body: body))
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConvoPinError, expected, file: file, line: line)
        }
    }

    // MARK: - Live frame

    func testPinsFrameCarriesTheWholeList() {
        let text = #"{"kind":"pins","pins":[{"convo_id":"b","label":"B","position":1},{"convo_id":"a","label":"A","emoji":"📮","position":0}]}"#
        guard case let .pins(pins)? = ServerFrame.decode(text) else { return XCTFail("expected a pins frame") }
        XCTAssertEqual(pins.map(\.convoID), ["a", "b"])
        XCTAssertEqual(pins.first?.emoji, "📮")
        if case .pins(let empty)? = ServerFrame.decode(#"{"kind":"pins","pins":[]}"#) {
            XCTAssertEqual(empty, [], "the last unpin is an empty list, not nothing")
        } else {
            XCTFail("expected an empty pins frame")
        }
        XCTAssertNil(ServerFrame.decode(#"{"kind":"pins"}"#))
    }
}

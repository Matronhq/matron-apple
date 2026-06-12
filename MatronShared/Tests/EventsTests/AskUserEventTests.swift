import XCTest
@testable import MatronEvents

final class AskUserEventTests: XCTestCase {
    func test_parses_text() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "What's your name?",
            "input": ["kind": "text"]
        ]))
        XCTAssertEqual(evt.prompt, "What's your name?")
        XCTAssertEqual(evt.kind, .text)
        XCTAssertNil(evt.expiresAt)
    }

    func test_parses_choice() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "Which file?",
            "input": [
                "kind": "choice",
                "allow_other": true,
                "options": [
                    ["id": "a", "label": "main.rs"],
                    ["id": "b", "label": "lib.rs"]
                ]
            ]
        ]))
        guard case .choice(let options, let allowOther) = evt.kind else {
            return XCTFail("Expected .choice")
        }
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options[0], AskUserEvent.Option(id: "a", label: "main.rs"))
        XCTAssertEqual(options[1], AskUserEvent.Option(id: "b", label: "lib.rs"))
        XCTAssertTrue(allowOther)
    }

    func test_parses_multiChoice_defaultsAllowOtherToFalse() throws {
        // `allow_other` omitted → parser defaults to false. Multi-
        // choice without "Other" is a sensible default for picking
        // multiple from a closed list.
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "Pick languages",
            "input": [
                "kind": "multi_choice",
                "options": [
                    ["id": "swift", "label": "Swift"],
                    ["id": "rust", "label": "Rust"]
                ]
            ]
        ]))
        guard case .multiChoice(let options, let allowOther) = evt.kind else {
            return XCTFail("Expected .multiChoice")
        }
        XCTAssertEqual(options.count, 2)
        XCTAssertFalse(allowOther)
    }

    func test_parses_boolean() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "Continue?",
            "input": ["kind": "boolean"]
        ]))
        XCTAssertEqual(evt.kind, .boolean)
    }

    func test_parses_expiresAt() throws {
        // ms-since-epoch → Date(timeIntervalSince1970:) at /1000.
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": ["kind": "text"],
            "expires_at": 1745000000000.0,
        ]))
        XCTAssertEqual(evt.expiresAt?.timeIntervalSince1970, 1745000000.0)
    }

    func test_skipsMalformedOptionEntries() throws {
        // An options array with one well-formed and one malformed
        // entry — compactMap drops the malformed one rather than
        // failing the whole event. (The bot can land partial
        // updates without bricking the user's UI.)
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": [
                "kind": "choice",
                "options": [
                    ["id": "a", "label": "Apple"],
                    ["label": "missing id"],          // malformed
                    ["id": "b", "label": "Banana"],
                ]
            ]
        ]))
        guard case .choice(let options, _) = evt.kind else {
            return XCTFail("Expected .choice")
        }
        XCTAssertEqual(options.count, 2)
        XCTAssertEqual(options.map(\.id), ["a", "b"])
    }

    func test_returnsNil_whenPromptMissing() {
        XCTAssertNil(AskUserEvent.parse(content: [
            "input": ["kind": "text"]
        ]))
    }

    func test_returnsNil_whenInputKindMissing() {
        XCTAssertNil(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": [:],
        ]))
    }

    func test_returnsNil_whenInputKindUnknown() {
        XCTAssertNil(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": ["kind": "alien"]
        ]))
    }

    func test_parse_setsTextReplyChannel() throws {
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": ["kind": "text"]
        ]))
        XCTAssertEqual(evt.replyChannel, .textReply)
    }

    func test_parse_optionValueDefaultsToLabel() throws {
        // ask_user options carry no `value` field — replies send the
        // label text per spec §4.2, so the parsed Option's value must
        // equal its label.
        let evt = try XCTUnwrap(AskUserEvent.parse(content: [
            "prompt": "x",
            "input": [
                "kind": "choice",
                "options": [["id": "a", "label": "main.rs"]]
            ]
        ]))
        guard case .choice(let options, _) = evt.kind else {
            return XCTFail("Expected .choice")
        }
        XCTAssertEqual(options[0].value, "main.rs")
    }

    // MARK: - parseButtons (Matron X / bridge buttons protocol)

    /// Content shape as emitted by claude-matrix-bridge
    /// `sendButtonMessage` — the buttons dict lives under the
    /// `chat.matron.buttons` content key on an m.room.message.
    private func buttonsContent(
        mode: String = "pick_one",
        buttons: [[String: Any]] = [["id": "a", "label": "Yes", "value": "yes"]]
    ) -> [String: Any] {
        [
            "msgtype": "m.text",
            "body": "Pick one: Yes",
            "chat.matron.buttons": [
                "mode": mode,
                "prompt": "Proceed?",
                "buttons": buttons,
            ],
        ]
    }

    func test_parseButtons_pickOne_mapsToChoice() throws {
        let evt = try XCTUnwrap(AskUserEvent.parseButtons(content: buttonsContent(
            mode: "pick_one",
            buttons: [
                ["id": "a", "label": "Send now", "value": "interrupt"],
                ["id": "b", "label": "Cancel message 1", "value": "cancel:0"],
            ]
        )))
        XCTAssertEqual(evt.prompt, "Proceed?")
        XCTAssertEqual(evt.replyChannel, .buttonResponse)
        XCTAssertNil(evt.expiresAt)
        guard case .choice(let options, let allowOther) = evt.kind else {
            return XCTFail("Expected .choice")
        }
        XCTAssertFalse(allowOther)
        XCTAssertEqual(options.map(\.label), ["Send now", "Cancel message 1"])
        // The wire `value` (what selected_values carries) is distinct
        // from the label — must be preserved verbatim.
        XCTAssertEqual(options.map(\.value), ["interrupt", "cancel:0"])
    }

    func test_parseButtons_pickMany_mapsToMultiChoice() throws {
        let evt = try XCTUnwrap(AskUserEvent.parseButtons(content: buttonsContent(mode: "pick_many")))
        guard case .multiChoice = evt.kind else {
            return XCTFail("Expected .multiChoice")
        }
    }

    func test_parseButtons_returnsNil_whenModeUnknown() {
        XCTAssertNil(AskUserEvent.parseButtons(content: buttonsContent(mode: "pick_some")))
    }

    func test_parseButtons_returnsNil_whenNoButtonsKey() {
        XCTAssertNil(AskUserEvent.parseButtons(content: [
            "msgtype": "m.text", "body": "plain message"
        ]))
    }

    func test_parseButtons_returnsNil_whenAllButtonsMalformed() {
        // Matron X parity: `guard !buttons.isEmpty` — a buttons dict
        // whose entries all drop a required field degrades to the
        // plaintext fallback rather than an empty sheet.
        XCTAssertNil(AskUserEvent.parseButtons(content: buttonsContent(
            buttons: [["id": "a", "label": "no value field"]]
        )))
    }
}

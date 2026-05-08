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
}

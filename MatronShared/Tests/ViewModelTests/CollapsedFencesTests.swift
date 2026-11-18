import XCTest
import MatronModels

final class CollapsedFencesTests: XCTestCase {
    private let body = """
    Here is what runs:

    ```json collapsed
    {"room_id":"room-a"}
    ```

    Allow once or Decline.
    """

    func test_foldedBlockBecomesOneShowLink() {
        let drawn = CollapsedFences.present(body, key: "body#0", expanded: [])
        let id = CollapsedFences.foldID(key: "body#0", index: 0)
        let link = CollapsedFences.url(for: id).absoluteString
        let copy = CollapsedFences.copyURL(for: id).absoluteString
        XCTAssertEqual(drawn, """
        Here is what runs:

        [▸ Show json](\(link)) · [Copy](\(copy))

        Allow once or Decline.
        """)
    }

    func test_openBlockKeepsItsCodeUnderAHideLink() {
        let id = CollapsedFences.foldID(key: "body#0", index: 0)
        let drawn = CollapsedFences.present(body, key: "body#0", expanded: [id])
        XCTAssertTrue(drawn.contains("[▾ Hide json](\(CollapsedFences.url(for: id).absoluteString))\n\n```json\n{\"room_id\":\"room-a\"}\n```"))
        XCTAssertFalse(drawn.contains("collapsed"), "the open block's info string is just its language")
    }

    func test_textWithoutAFoldableBlockIsUnchanged() {
        for source in ["plain words", "```json\n{}\n```", "a word collapsed in prose",
                       "```collapsed\nonly a language called collapsed\n```",
                       "```json collapsed\nnever closed"] {
            XCTAssertEqual(CollapsedFences.present(source, key: "k", expanded: []), source)
        }
    }

    /// The word inside another block's code opens nothing, and a longer
    /// fence holds a shorter one.
    func test_onlyRealFencesFold() {
        let source = "````text\n```json collapsed\n{}\n```\n````"
        XCTAssertEqual(CollapsedFences.present(source, key: "k", expanded: []), source)
        let tildes = "~~~~json collapsed\n```\n~~~~"
        XCTAssertTrue(CollapsedFences.present(tildes, key: "k", expanded: []).hasPrefix("[▸ Show json]"))
    }

    func test_eachBlockHasItsOwnID() {
        let source = "```json collapsed\n1\n```\n```sh collapsed\n2\n```"
        let second = CollapsedFences.foldID(key: "k", index: 1)
        let drawn = CollapsedFences.present(source, key: "k", expanded: [second])
        XCTAssertTrue(drawn.contains("▸ Show json"))
        XCTAssertTrue(drawn.contains("▾ Hide sh"))
        XCTAssertTrue(drawn.contains("```sh\n2\n```"))
    }

    func test_toggleLinkRoundTripsAnyID() {
        let id = CollapsedFences.foldID(key: "comment:a b)c#2", index: 3)
        let url = CollapsedFences.url(for: id)
        XCTAssertEqual(CollapsedFences.foldID(from: url), id)
        XCTAssertFalse(url.absoluteString.contains(" ") || url.absoluteString.contains(")"))
        XCTAssertNil(CollapsedFences.foldID(from: URL(string: "https://example.com/?id=x")!))
        XCTAssertEqual(CollapsedFences.link(from: CollapsedFences.copyURL(for: id)), .copy(id))
        XCTAssertEqual(CollapsedFences.link(from: url), .toggle(id))
        XCTAssertNil(CollapsedFences.foldID(from: CollapsedFences.copyURL(for: id)), "a copy link toggles nothing")
    }

    /// A folded block's Copy copies its whole code, as written.
    func test_codeOfABlockIsItsCodeAsWritten() {
        let source = "```json collapsed\n{\"a\":1,\n \"b\":\"x y\"}\n```\n\n```sh collapsed\nls\n```"
        XCTAssertEqual(CollapsedFences.code(of: CollapsedFences.foldID(key: "k", index: 0), key: "k", in: source),
                       "{\"a\":1,\n \"b\":\"x y\"}")
        XCTAssertEqual(CollapsedFences.code(of: CollapsedFences.foldID(key: "k", index: 1), key: "k", in: source), "ls")
        XCTAssertNil(CollapsedFences.code(of: CollapsedFences.foldID(key: "k", index: 2), key: "k", in: source))
        XCTAssertNil(CollapsedFences.code(of: CollapsedFences.foldID(key: "other", index: 0), key: "k", in: source))
    }
}

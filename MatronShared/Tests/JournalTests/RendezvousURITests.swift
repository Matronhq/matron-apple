import XCTest
@testable import MatronJournal

final class RendezvousURITests: XCTestCase {
    private let rid = "23456789BCDFGHJKMNPQRSTVWX" // 26 chars, all in alphabet

    func test_format_roundTripsThroughParse() throws {
        let uri = RendezvousURI.format(rid: rid)
        XCTAssertEqual(uri, "matron://rlink?v=1&rid=\(rid)")
        XCTAssertEqual(try RendezvousURI.parse(uri), rid)
    }

    func test_parse_rejectsNonRlinkPayloads_asNotALink() {
        for raw in ["https://example.com", "matron://link?v=1&server=x&code=ABCD-2345", "random text", ""] {
            XCTAssertThrowsError(try RendezvousURI.parse(raw)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .notALink, raw)
            }
        }
    }

    func test_parse_futureVersion_isUnsupported_butMissingVersionIsMalformed() {
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?v=2&rid=\(rid)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?rid=\(rid)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .malformed)
        }
    }

    func test_parse_ridShapeIsEnforced() {
        for bad in [
            "matron://rlink?v=1",                                  // missing rid
            "matron://rlink?v=1&rid=SHORT",                        // wrong length
            "matron://rlink?v=1&rid=\(String(repeating: "A", count: 26))", // A not in alphabet
            "matron://rlink?v=1&rid=\(rid)X",                      // 27 chars
        ] {
            XCTAssertThrowsError(try RendezvousURI.parse(bad)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .malformed, bad)
            }
        }
    }
}

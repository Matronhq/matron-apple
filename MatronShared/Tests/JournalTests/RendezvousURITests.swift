import XCTest
@testable import MatronJournal

final class RendezvousURITests: XCTestCase {
    private let rid = "23456789BCDFGHJKMNPQRSTVWX" // 26 chars, all in alphabet
    // 32 bytes 0x00..0x1f — base64url "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let key = Data((0..<32).map { UInt8($0) })
    private var keyB64: String { "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8" }

    func test_format_roundTripsThroughParse() throws {
        let uri = RendezvousURI.format(rid: rid, key: key)
        XCTAssertEqual(uri, "matron://rlink?v=2&rid=\(rid)&k=\(keyB64)")
        let parsed = try RendezvousURI.parse(uri)
        XCTAssertEqual(parsed.rid, rid)
        XCTAssertEqual(parsed.key, key)
    }

    func test_parse_rejectsNonRlinkPayloads_asNotALink() {
        for raw in ["https://example.com", "matron://link?v=2&server=x&code=ABCD-2345", "random text", ""] {
            XCTAssertThrowsError(try RendezvousURI.parse(raw)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .notALink, raw)
            }
        }
    }

    func test_parse_v1_isNowUnsupported_andMissingVersionIsMalformed() {
        // Hard cutover: v=1 (the shipped cleartext format) is no longer honored.
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?v=1&rid=\(rid)&k=\(keyB64)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?v=3&rid=\(rid)&k=\(keyB64)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .unsupportedVersion)
        }
        XCTAssertThrowsError(try RendezvousURI.parse("matron://rlink?rid=\(rid)&k=\(keyB64)")) {
            XCTAssertEqual($0 as? RendezvousURI.ParseError, .malformed)
        }
    }

    func test_parse_ridShapeIsEnforced() {
        for bad in [
            "matron://rlink?v=2&k=\(keyB64)",                                       // missing rid
            "matron://rlink?v=2&rid=SHORT&k=\(keyB64)",                             // wrong length
            "matron://rlink?v=2&rid=\(String(repeating: "A", count: 26))&k=\(keyB64)", // A not in alphabet
            "matron://rlink?v=2&rid=\(rid)X&k=\(keyB64)",                           // 27 chars
        ] {
            XCTAssertThrowsError(try RendezvousURI.parse(bad)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .malformed, bad)
            }
        }
    }

    func test_parse_keyIsRequiredAndMustBe32Bytes() {
        for bad in [
            "matron://rlink?v=2&rid=\(rid)",                          // missing k
            "matron://rlink?v=2&rid=\(rid)&k=",                       // empty k
            "matron://rlink?v=2&rid=\(rid)&k=not!base64url",          // undecodable
            "matron://rlink?v=2&rid=\(rid)&k=AAEC",                   // decodes to 3 bytes, not 32
        ] {
            XCTAssertThrowsError(try RendezvousURI.parse(bad)) { error in
                XCTAssertEqual(error as? RendezvousURI.ParseError, .malformed, bad)
            }
        }
    }

    func test_parse_isCaseInsensitiveOnSchemeAndHost() throws {
        let parsed = try RendezvousURI.parse("MATRON://RLINK?v=2&rid=\(rid)&k=\(keyB64)")
        XCTAssertEqual(parsed.rid, rid)
        XCTAssertEqual(parsed.key, key)
    }

    func test_parse_duplicateRidKeys_firstWins() throws {
        let ridB = String(rid.reversed())
        let parsed = try RendezvousURI.parse("matron://rlink?v=2&rid=\(rid)&rid=\(ridB)&k=\(keyB64)")
        XCTAssertEqual(parsed.rid, rid)
    }
}

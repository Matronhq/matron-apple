import XCTest
@testable import MatronJournal

final class LinkURITests: XCTestCase {
    func test_roundTrip() throws {
        let server = URL(string: "https://chat.example.com")!
        let uri = LinkURI.format(server: server, code: "KTNM-3VQ8")
        XCTAssertTrue(uri.hasPrefix("matron://link?"))
        let parsed = try LinkURI.parse(uri)
        XCTAssertEqual(parsed.server, server)
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_roundTrip_serverWithPathPrefixAndPort() throws {
        // The server URL is embedded exactly as the session stores it —
        // subpath-hosted and non-443 servers must survive the round trip.
        let server = URL(string: "http://127.0.0.1:9810/journal")!
        let parsed = try LinkURI.parse(LinkURI.format(server: server, code: "KTNM-3VQ8"))
        XCTAssertEqual(parsed.server, server)
    }

    func test_parse_normalizesSloppyCode() throws {
        let parsed = try LinkURI.parse("matron://link?v=1&server=https%3A%2F%2Fchat.example.com&code=ktnm3vq8")
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_parse_wrongSchemeOrHost_isNotALink() {
        for raw in ["https://chat.example.com", "matron://pair?v=1", "otp://x", "not a uri at all"] {
            XCTAssertThrowsError(try LinkURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? LinkURI.ParseError, .notALink, raw)
            }
        }
    }

    func test_parse_otherVersion_isUnsupported() {
        XCTAssertThrowsError(try LinkURI.parse("matron://link?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")) {
            XCTAssertEqual($0 as? LinkURI.ParseError, .unsupportedVersion)
        }
    }

    func test_parse_missingOrBadParts_isMalformed() {
        for raw in [
            "matron://link?server=https%3A%2F%2Fx.example&code=KTNM-3VQ8", // no v
            "matron://link?v=1&code=KTNM-3VQ8",                            // no server
            "matron://link?v=1&server=ftp%3A%2F%2Fx.example&code=KTNM-3VQ8", // non-http(s) server
            "matron://link?v=1&server=https%3A%2F%2Fx.example",            // no code
            "matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTN",   // short code
        ] {
            XCTAssertThrowsError(try LinkURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? LinkURI.ParseError, .malformed, raw)
            }
        }
    }
}

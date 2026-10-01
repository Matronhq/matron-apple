import XCTest
@testable import MatronJournal

final class PairURITests: XCTestCase {
    func test_roundTrip() throws {
        let server = URL(string: "https://chat.example.com")!
        let uri = PairURI.format(server: server, code: "KTNM-3VQ8")
        XCTAssertTrue(uri.hasPrefix("matron://pair?"))
        let parsed = try PairURI.parse(uri)
        XCTAssertEqual(parsed.server, server)
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_roundTrip_serverWithPathPrefixAndPort() throws {
        let server = URL(string: "http://127.0.0.1:9810/journal")!
        let parsed = try PairURI.parse(PairURI.format(server: server, code: "KTNM-3VQ8"))
        XCTAssertEqual(parsed.server, server)
    }

    func test_parse_normalizesSloppyCode_andTrimsWhitespace() throws {
        let parsed = try PairURI.parse(" matron://pair?v=1&server=https%3A%2F%2Fchat.example.com&code=ktnm3vq8\n")
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_parse_isCaseInsensitiveOnSchemeAndHost() throws {
        let parsed = try PairURI.parse("MATRON://PAIR?v=1&server=https%3A%2F%2Fchat.example.com&code=KTNM-3VQ8")
        XCTAssertEqual(parsed.server, URL(string: "https://chat.example.com")!)
        XCTAssertEqual(parsed.code, "KTNM-3VQ8")
    }

    func test_parse_wrongSchemeOrHost_isNotAPairURI() {
        for raw in ["https://chat.example.com",
                    "matron://link?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8",
                    "otp://x", "not a uri at all", "KTNM-3VQ8"] {
            XCTAssertFalse(PairURI.isPairURI(raw), raw)
            XCTAssertThrowsError(try PairURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? PairURI.ParseError, .notAPairURI, raw)
            }
        }
    }

    func test_parse_otherVersion_isUnsupported() {
        XCTAssertThrowsError(try PairURI.parse("matron://pair?v=2&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8")) {
            XCTAssertEqual($0 as? PairURI.ParseError, .unsupportedVersion)
        }
    }

    func test_parse_cleartextHttp_onlyForLocalhost() throws {
        XCTAssertThrowsError(try PairURI.parse("matron://pair?v=1&server=http%3A%2F%2F192.168.1.10%3A8787&code=KTNM-3VQ8")) {
            XCTAssertEqual($0 as? PairURI.ParseError, .malformed)
        }
        for host in ["localhost", "127.0.0.1"] {
            let parsed = try PairURI.parse("matron://pair?v=1&server=http%3A%2F%2F\(host)%3A8787&code=KTNM-3VQ8")
            XCTAssertEqual(parsed.server, URL(string: "http://\(host):8787")!, host)
        }
    }

    func test_parse_missingOrBadParts_isMalformed() {
        for raw in [
            "matron://pair?server=https%3A%2F%2Fx.example&code=KTNM-3VQ8",   // no v
            "matron://pair?v=1&code=KTNM-3VQ8",                              // no server
            "matron://pair?v=1&server=ftp%3A%2F%2Fx.example&code=KTNM-3VQ8", // non-http(s) server
            "matron://pair?v=1&server=https%3A%2F%2F&code=KTNM-3VQ8",        // no host
            "matron://pair?v=1&server=https%3A%2F%2Fx.example",              // no code
            "matron://pair?v=1&server=https%3A%2F%2Fx.example&code=KTN",     // short code
            "matron://pair?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQ8X", // long code
            "matron://pair?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQA",  // vowel: off-alphabet
            "matron://pair?v=1&server=https%3A%2F%2Fx.example&code=KTNM-3VQL",  // L: off-alphabet
        ] {
            XCTAssertThrowsError(try PairURI.parse(raw), raw) { error in
                XCTAssertEqual(error as? PairURI.ParseError, .malformed, raw)
            }
        }
    }

    func test_sameOrigin_ignoresCasePathAndDefaultPort() {
        let account = URL(string: "https://Chat.Example.com")!
        XCTAssertTrue(PairURI.sameOrigin(account, URL(string: "https://chat.example.com/")!))
        XCTAssertTrue(PairURI.sameOrigin(account, URL(string: "https://chat.example.com:443/journal")!))
        XCTAssertTrue(PairURI.sameOrigin(URL(string: "http://localhost:8787")!, URL(string: "http://LOCALHOST:8787/")!))
    }

    func test_sameOrigin_differsOnHostSchemeOrPort() {
        let account = URL(string: "https://chat.example.com")!
        XCTAssertFalse(PairURI.sameOrigin(account, URL(string: "https://evil.example.com")!))
        XCTAssertFalse(PairURI.sameOrigin(account, URL(string: "http://chat.example.com")!))
        XCTAssertFalse(PairURI.sameOrigin(account, URL(string: "https://chat.example.com:8443")!))
    }

    func test_displayHost_showsExplicitPortOnly() {
        XCTAssertEqual(PairURI.displayHost(URL(string: "https://chat.example.com/journal")!), "chat.example.com")
        XCTAssertEqual(PairURI.displayHost(URL(string: "http://localhost:8787")!), "localhost:8787")
    }
}

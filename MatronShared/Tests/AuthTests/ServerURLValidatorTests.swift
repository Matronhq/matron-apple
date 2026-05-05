import XCTest
@testable import MatronAuth

final class ServerURLValidatorTests: XCTestCase {
    func test_validates_simpleHTTPS() throws {
        let url = try ServerURLValidator.normalize("https://matrix.example.com")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_addsHTTPS_whenMissingScheme() throws {
        let url = try ServerURLValidator.normalize("matrix.example.com")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_stripsTrailingSlash() throws {
        let url = try ServerURLValidator.normalize("https://matrix.example.com/")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }

    func test_rejects_HTTP() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("http://matrix.example.com")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .insecureScheme)
        }
    }

    /// Plain `http://localhost` is allowed — matron's integration harness
    /// (Docker matron-server) listens on `http://localhost:6167` and
    /// Element Web does the same. Production homeservers always run
    /// behind HTTPS so the carve-out can't expose remote creds.
    func test_allows_HTTP_localhost() throws {
        let url = try ServerURLValidator.normalize("http://localhost:6167")
        XCTAssertEqual(url.absoluteString, "http://localhost:6167")
    }

    func test_allows_HTTP_127_0_0_1() throws {
        let url = try ServerURLValidator.normalize("http://127.0.0.1:6167")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:6167")
    }

    func test_rejects_HTTP_nonLocalhost() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("http://192.168.1.5:6167")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .insecureScheme)
        }
    }

    func test_rejects_emptyString() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .empty)
        }
    }

    func test_rejects_whitespaceOnly() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("   ")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .empty)
        }
    }

    func test_rejects_invalidHost() {
        XCTAssertThrowsError(try ServerURLValidator.normalize("https:///")) { error in
            XCTAssertEqual(error as? ServerURLValidator.ValidationError, .noHost)
        }
    }

    func test_trimsLeadingAndTrailingWhitespace() throws {
        let url = try ServerURLValidator.normalize("  matrix.example.com  ")
        XCTAssertEqual(url.absoluteString, "https://matrix.example.com")
    }
}

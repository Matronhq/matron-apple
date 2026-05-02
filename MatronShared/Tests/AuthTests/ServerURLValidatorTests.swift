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

import XCTest
@testable import MatronChat

/// Pins link extraction for the Links tab. NSDataDetector handles the messy
/// shapes (markdown, angle brackets, trailing punctuation); these tests pin
/// the scheme filter and multi-URL behavior without over-specifying detector
/// internals that vary by OS build (hence hasPrefix, not equality, where
/// punctuation is involved).
final class LinkExtractorTests: XCTestCase {
    func testBareURL() {
        XCTAssertEqual(LinkExtractor.links(in: "deployed to https://example.com/app"),
                       [URL(string: "https://example.com/app")!])
    }

    func testMarkdownAndTrailingPunctuation() {
        let links = LinkExtractor.links(in: "see [docs](https://example.com/docs). Done.")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].absoluteString.hasPrefix("https://example.com/docs"))
    }

    func testNonHTTPSchemesRejected() {
        XCTAssertEqual(LinkExtractor.links(in: "mail me mailto:a@b.c or ftp://files.example"), [])
    }

    func testMultipleURLsKeepDocumentOrder() {
        let links = LinkExtractor.links(in: "first https://a.example then http://b.example")
        XCTAssertEqual(links.map(\.host), ["a.example", "b.example"])
    }

    func testPlainTextYieldsNothing() {
        XCTAssertEqual(LinkExtractor.links(in: "http on its own is not a link"), [])
    }
}

import XCTest
import SwiftUI
import MarkdownUI
@testable import MatronDesignSystem

/// Tracker-item deep links (`[#65](matron://item/65)`, item #115). Agents
/// write them into ordinary message bodies, so the parser is the boundary
/// between "open item 65" and "hand an unregistered scheme to the OS" —
/// hence the table test on both the accepted AND the rejected forms.
final class MatronItemLinkTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return URL(string: "about:blank")!
        }
        return url
    }

    // MARK: - Parsing

    func test_itemNumber_acceptsCanonicalForm() {
        let accepted: [(String, Int)] = [
            ("matron://item/65", 65),
            ("matron://item/1", 1),
            ("matron://item/123456", 123_456),
            // Scheme + host are case-insensitive per RFC 3986.
            ("MATRON://item/65", 65),
            ("Matron://ITEM/65", 65),
        ]
        for (string, expected) in accepted {
            XCTAssertEqual(MatronItemLink.itemNumber(from: url(string)), expected,
                           "\(string) should parse as item \(expected)")
        }
    }

    func test_itemNumber_rejectsEverythingElse() {
        let rejected = [
            "matron://item/",            // no number
            "matron://item",             // no path at all
            "matron://item/abc",         // not a number
            "matron://item/65abc",       // trailing junk
            "matron://items/65",         // wrong host
            "matron://item/65/extra",    // extra path component
            "matron://item/-5",          // negative
            "matron://item/0",           // zero is not an item number
            "matron://item/+65",         // signed
            "matron://item/65?x=1",      // query
            "matron://item/65#frag",     // fragment
            "matron://link/abc",         // the pairing-link scheme
            "https://matron.chat/item/65",
            "matrix://item/65",
            "item://65",
        ]
        for string in rejected {
            XCTAssertNil(MatronItemLink.itemNumber(from: url(string)),
                         "\(string) must not parse as an item link")
        }
    }

    // MARK: - Link policy (shared by both message renderers)

    func test_action_routesByScheme() {
        XCTAssertEqual(MatronItemLink.action(for: url("matron://item/65")), .openTrackerItem(65))
        XCTAssertEqual(MatronItemLink.action(for: url("https://matron.chat")),
                       .system(url("https://matron.chat")))
        XCTAssertEqual(MatronItemLink.action(for: url("mxc://server/abc")), .swallow)
        XCTAssertEqual(MatronItemLink.action(for: url("matrix://room/abc")), .swallow)
        // A `matron://` URL that is NOT an item link keeps the pre-existing
        // default policy (unknown scheme → the system's own error sheet).
        XCTAssertEqual(MatronItemLink.action(for: url("matron://item/abc")),
                       .system(url("matron://item/abc")))
    }

    // MARK: - MarkdownText (iOS message bodies + non-timeline Mac contexts)

    func test_handle_itemLink_callsHandler() {
        var opened: [Int] = []
        _ = MarkdownText.handle(url: url("matron://item/65"), openItem: { opened.append($0) })
        XCTAssertEqual(opened, [65])
    }

    func test_handle_neverRoutesNonItemURLsToTheItemHandler() {
        var opened: [Int] = []
        let handler: (Int) -> Void = { opened.append($0) }
        for string in ["https://matron.chat", "mxc://server/abc", "matron://item/abc"] {
            _ = MarkdownText.handle(url: url(string), openItem: handler)
        }
        XCTAssertTrue(opened.isEmpty)
    }

    /// The rendering half of the iOS path: MarkdownUI (cmark) must parse
    /// `[#65](matron://item/65)` as an inline LINK whose text is `#65` and
    /// whose destination survives intact — otherwise the tap never reaches
    /// the `openURL` policy above. (The Mac timeline's converter is pinned
    /// separately in `MessageLinkClickTests`.)
    func test_markdownUIParsesAnItemLinkAsALink() {
        let content = MarkdownText.content(for: "See [#65](matron://item/65) for details.", cache: false)
        // (MarkdownUI's re-serializer escapes the `#` as `\#` — cosmetic to
        // this assertion; what matters is that the destination round-trips
        // as a link rather than as literal text.)
        XCTAssertTrue(content.renderMarkdown().contains("](matron://item/65)"),
                      "parsed as an inline link, not literal text: \(content.renderMarkdown())")
        XCTAssertEqual(content.renderPlainText(), "See #65 for details.",
                       "the visible link text is `#65`")
    }

    // MARK: - Tap relay

    func test_relay_publishesEachTapSeparately() {
        let relay = TrackerItemLinkRelay()
        XCTAssertNil(relay.pending)
        relay.action(65)
        XCTAssertEqual(relay.pending?.num, 65)
        let first = relay.pending
        // Two taps on the SAME item must be two distinct pending values, or
        // the host view's `onChange` would ignore the second one.
        relay.action(65)
        XCTAssertEqual(relay.pending?.num, 65)
        XCTAssertNotEqual(relay.pending, first)
    }
}

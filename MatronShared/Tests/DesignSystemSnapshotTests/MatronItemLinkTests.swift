import XCTest
import SwiftUI
import MarkdownUI
import MatronModels
@testable import MatronDesignSystem

/// Tracker-item deep links (`[#65](matron://item/65)`). Agents
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
            ("matron://item/" + "123456", 123_456),
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
            "matron://item/xyz",         // not a number
            "matron://item/65xyz",       // trailing junk
            "matron://items/65",         // wrong host
            "matron://item/65/extra",    // extra path component
            "matron://item/65/",         // trailing empty segment
            "matron://item//65",         // leading empty segment
            "matron://item///",          // nothing but separators
            "matron://item/65//",        // trailing separators
            "matron://item/6 5",         // internal space
            "matron://item/%36%35",      // percent-encoded digits
            "matron://item:80/65",       // port
            "matron://alice@item/65",      // userinfo
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

    // MARK: - Mission and project links

    func test_pageLink_acceptsCanonicalForm() {
        let accepted: [(String, MatronPageLink)] = [
            ("matron://mission/61", .mission(61)),
            ("matron://project/12", .project(12)),
            ("MATRON://Mission/61", .mission(61)),
            ("matron://PROJECT/12", .project(12)),
        ]
        for (string, expected) in accepted {
            XCTAssertEqual(MatronItemLink.pageLink(from: url(string)), expected, string)
            XCTAssertEqual(MatronItemLink.action(for: url(string)), .openPage(expected), string)
        }
    }

    /// Held to the item parser's canonical form: anything else is not a
    /// page link, and — being a `matron://` URL — is swallowed.
    func test_pageLink_rejectsEverythingElse() {
        let rejected = [
            "matron://mission/", "matron://mission", "matron://mission/xyz", "matron://mission/61xyz",
            "matron://missions/61", "matron://mission/61/extra", "matron://mission/61/",
            "matron://mission//61", "matron://mission/%36%31", "matron://mission:80/61",
            "matron://alice@mission/61", "matron://mission/0", "matron://mission/-1",
            "matron://mission/61?x=1", "matron://mission/61#frag",
            "matron://project/", "matron://project/abc", "matron://projects/12",
            "matron://project/12/extra", "matron://project/0", "matron://project/12?x=1",
        ]
        for string in rejected {
            XCTAssertNil(MatronItemLink.pageLink(from: url(string)), "\(string) must not parse as a page link")
            XCTAssertEqual(MatronItemLink.action(for: url(string)), .swallow, string)
        }
        // An item link is not a page link, and the reverse.
        XCTAssertNil(MatronItemLink.pageLink(from: url("matron://item/65")))
        XCTAssertNil(MatronItemLink.itemNumber(from: url("matron://mission/61")))
        XCTAssertNil(MatronItemLink.pageLink(from: url("https://matron.chat/mission/61")))
    }

    // MARK: - Link policy (shared by both message renderers)

    func test_action_routesByScheme() {
        XCTAssertEqual(MatronItemLink.action(for: url("matron://item/65")), .openTrackerItem(65))
        XCTAssertEqual(MatronItemLink.action(for: url("https://matron.chat")),
                       .system(url("https://matron.chat")))
        XCTAssertEqual(MatronItemLink.action(for: url("mxc://server/abc")), .swallow)
        XCTAssertEqual(MatronItemLink.action(for: url("matrix://room/abc")), .swallow)
    }

    /// No `matron://` URL may ever reach the OS: the scheme is registered
    /// with nothing, so the system answers with a "no application can open
    /// this URL" sheet. Malformed item links and linkified pairing URLs are
    /// swallowed, not passed on.
    func test_action_swallowsEveryMatronURL() {
        for string in ["matron://item/xyz", "matron://item/", "matron://item/65/extra",
                       "matron://items/65", "matron://link/abc", "matron://rlink/abc",
                       "MATRON://whatever"] {
            XCTAssertEqual(MatronItemLink.action(for: url(string)), .swallow,
                           "\(string) must be swallowed, never handed to the OS")
        }
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
        for string in ["https://matron.chat", "mxc://server/abc", "matron://item/xyz"] {
            _ = MarkdownText.handle(url: url(string), openItem: handler)
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func test_handle_routesEachMatronLinkToItsOwnHandler() {
        var items: [Int] = []
        var conversations: [String] = []
        var pages: [MatronPageLink] = []
        for string in ["matron://item/65", "matron://convo/c-1", "matron://mission/61", "matron://project/12",
                       "matron://link/abc"] {
            _ = MarkdownText.handle(url: url(string), openItem: { items.append($0) },
                                    openConversation: { conversations.append($0) },
                                    openPage: { pages.append($0) })
        }
        XCTAssertEqual(items, [65])
        XCTAssertEqual(conversations, ["c-1"])
        XCTAssertEqual(pages, [.mission(61), .project(12)])
    }

    /// `.systemAction` on a `matron://` URL is the bug this guards: SwiftUI
    /// would hand it to `UIApplication`/`NSWorkspace`, which has no handler
    /// for the scheme. `OpenURLAction.Result` isn't `Equatable`, so the
    /// policy itself is pinned in `test_action_swallowsEveryMatronURL` and
    /// this pins that `handle` asks that policy rather than the raw scheme.
    func test_handle_malformedItemLink_doesNotReachTheItemHandler() {
        var opened: [Int] = []
        _ = MarkdownText.handle(url: url("matron://link/abc"), openItem: { opened.append($0) })
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

    // MARK: - Log redaction

    /// Swallowed links are logged, and a linkified pairing URI carries its
    /// secret in the QUERY (`matron://rlink?…&k=<32-byte offer key>`,
    /// `matron://link?…&code=…`). The log form keeps scheme, host and path
    /// and drops everything after them (CodeRabbit, #115 round 4).
    func test_redactedForLog_stripsQueryAndFragment() {
        XCTAssertEqual(MatronItemLink.redactedForLog(url("matron://rlink?k=abc#x")), "matron://rlink")
        XCTAssertEqual(
            MatronItemLink.redactedForLog(url("matron://rlink?v=2&rid=01JABCDEF&k=c2VjcmV0LWtleQ")),
            "matron://rlink")
        XCTAssertEqual(
            MatronItemLink.redactedForLog(url("matron://link?v=1&server=https%3A%2F%2Fj.example&code=ABCD-1234")),
            "matron://link")
        // The diagnostic part — which item, which host — survives.
        XCTAssertEqual(MatronItemLink.redactedForLog(url("matron://item/65")), "matron://item/65")
        XCTAssertEqual(MatronItemLink.redactedForLog(url("https://example.com/a/b?token=t#frag")),
                       "https://example.com/a/b")
        // No host means the "path" IS the payload (`mailto:`, `matrix:`),
        // so only the scheme survives.
        XCTAssertEqual(MatronItemLink.redactedForLog(url("mailto:alice@example.com")), "mailto:…")
        XCTAssertEqual(MatronItemLink.redactedForLog(url("matrix:u/alice:example.com")), "matrix:…")
        // Whatever it returns, it must never contain the secret.
        for raw in ["matron://rlink?k=abc#x", "matron://link?code=ABCD-1234", "https://e.com/?token=t"] {
            let redacted = MatronItemLink.redactedForLog(url(raw))
            XCTAssertFalse(redacted.contains("?"), redacted)
            XCTAssertFalse(redacted.contains("#"), redacted)
        }
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

    @MainActor
    func test_pageRelay_publishesEachTapSeparately() {
        let relay = MatronPageLinkRelay()
        XCTAssertNil(relay.pending)
        relay.action(.mission(61))
        XCTAssertEqual(relay.pending?.link, .mission(61))
        let first = relay.pending
        relay.action(.mission(61))
        let second = relay.pending
        XCTAssertNotEqual(second, first, "a second tap on the same page is a new tap")
        guard let first, let second else { return XCTFail("both taps were published") }
        XCTAssertFalse(relay.isCurrent(first), "the first tap was overtaken")
        XCTAssertTrue(relay.isCurrent(second))
    }
}

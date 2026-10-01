import XCTest
@testable import MatronDesignSystem

/// A bare `matron://item/<n>` in prose is plain text to both markdown
/// parsers, so an agent's "the steps are on #5685 (matron://item/5685)"
/// could not be tapped. The pre-parse step wraps it in `<…>`, a CommonMark
/// autolink, everywhere except code and existing links.
final class MarkdownSourceItemLinkTests: XCTestCase {
    private func linked(_ s: String) -> String { MarkdownSource.linkingBareItemURLs(s) }

    func testBareItemURLInProseBecomesAnAutolink() {
        XCTAssertEqual(linked("The steps are on #5685 (matron://item/5685): step A."),
                       "The steps are on #5685 (<matron://item/5685>): step A.")
        XCTAssertEqual(linked("matron://item/1"), "<matron://item/1>")
        XCTAssertEqual(linked("See matron://item/12, then matron://item/13."),
                       "See <matron://item/12>, then <matron://item/13>.")
        XCTAssertEqual(linked("> quoted matron://item/7\n- listed matron://item/8"),
                       "> quoted <matron://item/7>\n- listed <matron://item/8>")
    }

    func testExistingLinksAreLeftAlone() {
        for body in ["[#12](matron://item/12)", "<matron://item/12>", "[see matron://item/12](matron://item/12)",
                     "[matron://item/12]", "\\<matron://item/12"] {
            XCTAssertEqual(linked(body), body, body)
        }
    }

    func testCodeIsLeftAlone() {
        for body in ["`matron://item/12`", "``a ` matron://item/12``", "```\nmatron://item/12\n```",
                     "    matron://item/12", "> ```\n> matron://item/12\n> ```"] {
            XCTAssertEqual(linked(body), body, body)
        }
        XCTAssertEqual(linked("`code` then matron://item/3"), "`code` then <matron://item/3>")
        XCTAssertEqual(linked("an unmatched ` then matron://item/3"), "an unmatched ` then <matron://item/3>")
    }

    func testOnlyTheCanonicalFormIsLinked() {
        for body in ["matron://item/", "matron://item/0", "matron://item/12/", "matron://item/12abc",
                     "matron://item/12?x=1", "matron://item/12#f", "xmatron://item/12", "MATRON://item/12",
                     "matron://convo/abc", "https://example.com/matron://item/12"] {
            XCTAssertEqual(linked(body), body, body)
        }
    }

    func testBothFixesCompose() {
        XCTAssertEqual(MarkdownSource.prepared("[Note]: see matron://item/5"), "\\[Note]: see <matron://item/5>")
    }
}

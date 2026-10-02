import XCTest
@testable import MatronSearch

final class SearchQueryTests: XCTestCase {
    func test_parse_splitsWords_andTreatsTheLastAsStillBeingTyped() throws {
        let query = try XCTUnwrap(SearchQuery("  time   cris"))
        XCTAssertEqual(query.terms, ["time", "cris"])
        XCTAssertTrue(query.lastTermIsPrefix)
        XCTAssertEqual(query.allTermsMatch, "\"time\" \"cris\"*")
        XCTAssertEqual(query.exactMatch, "\"time cris\"")
    }

    /// A trailing space is the user saying the word is finished.
    func test_parse_trailingSpaceFinishesTheLastWord() throws {
        let query = try XCTUnwrap(SearchQuery("time crisis "))
        XCTAssertFalse(query.lastTermIsPrefix)
        XCTAssertEqual(query.allTermsMatch, "\"time\" \"crisis\"")
    }

    func test_parse_nothingSearchable_isNil() {
        XCTAssertNil(SearchQuery(""))
        XCTAssertNil(SearchQuery("   "))
        XCTAssertNil(SearchQuery("++ --"), "punctuation leaves the tokenizer nothing to match")
    }

    /// Whatever is typed reaches FTS5 as quoted text, never as syntax.
    func test_match_quotesWhatWasTyped() throws {
        let query = try XCTUnwrap(SearchQuery("say \"hi\" NEAR x*"))
        XCTAssertEqual(query.allTermsMatch, "\"say\" \"\"\"hi\"\"\" \"NEAR\" \"x*\"*")
    }

    func test_parse_dropsWordsWithNothingToMatch() throws {
        let query = try XCTUnwrap(SearchQuery("deploy ++"))
        XCTAssertEqual(query.terms, ["deploy"])
        XCTAssertFalse(query.lastTermIsPrefix, "the dropped word still finished the one before it")
    }

    func test_isSearchable_needsTwoCharacters() throws {
        XCTAssertFalse(try XCTUnwrap(SearchQuery("t")).isSearchable)
        XCTAssertTrue(try XCTUnwrap(SearchQuery("ti")).isSearchable)
        XCTAssertTrue(try XCTUnwrap(SearchQuery("a b")).isSearchable)
    }

    func test_hasDistinctExactTier() throws {
        XCTAssertFalse(try XCTUnwrap(SearchQuery("time ")).hasDistinctExactTier)
        XCTAssertTrue(try XCTUnwrap(SearchQuery("time")).hasDistinctExactTier)
        XCTAssertTrue(try XCTUnwrap(SearchQuery("time crisis ")).hasDistinctExactTier)
    }

    /// Only plain ASCII words get a literal check: `LIKE` folds case for
    /// ASCII alone, and an apostrophe may be stored curly.
    func test_literalPatterns_coverPlainWordsOnly() throws {
        let query = try XCTUnwrap(SearchQuery("100% don't café deploy_now time"))
        XCTAssertEqual(query.literalPatterns, ["%time%"])
        XCTAssertNil(query.exactLiteralPattern)
        let plain = try XCTUnwrap(SearchQuery("time crisis"))
        XCTAssertEqual(plain.literalPatterns, ["%time%", "%crisis%"])
        XCTAssertEqual(plain.exactLiteralPattern, "%time crisis%")
    }

    // MARK: Snippets

    func test_snippet_highlightsTheTypedWords() throws {
        let query = try XCTUnwrap(SearchQuery("time crisis"))
        XCTAssertEqual(
            SearchSnippet.make(body: "Can you buy guns like Time Crisis guns", query: query),
            "Can you buy guns like <mark>Time Crisis</mark> guns")
    }

    /// The index matches words and word prefixes, so that is all the
    /// preview marks: "time" inside "sometimes" is not the hit.
    func test_snippet_marksWordStartsOnly() throws {
        let query = try XCTUnwrap(SearchQuery("time"))
        XCTAssertEqual(
            SearchSnippet.make(body: "sometimes the timer is on time", query: query),
            "sometimes the <mark>time</mark>r is on <mark>time</mark>")
    }

    /// Only the word still being typed is marked inside a longer word.
    func test_snippet_marksFinishedWordsWhole() throws {
        let query = try XCTUnwrap(SearchQuery("time cri"))
        XCTAssertEqual(
            SearchSnippet.make(body: "the timestamp, each time, was critical", query: query),
            "the timestamp, each <mark>time</mark>, was <mark>cri</mark>tical")
        // Matched through "times" alone: still shown, as the word start.
        let finished = try XCTUnwrap(SearchQuery("time "))
        XCTAssertEqual(SearchSnippet.make(body: "three times", query: finished), "three <mark>time</mark>s")
    }

    /// A message quoting the markup must not be read as a highlight.
    func test_snippet_dropsMarkupTheMessageItselfContains() throws {
        let query = try XCTUnwrap(SearchQuery("crisis"))
        XCTAssertEqual(
            SearchSnippet.make(body: "expected <mark>Time Crisis</mark> here", query: query),
            "expected Time <mark>Crisis</mark> here")
    }

    func test_snippet_opensNearTheFirstMatch_onOneLine() throws {
        let query = try XCTUnwrap(SearchQuery("needle"))
        let body = String(repeating: "filler words here ", count: 20) + "the\nneedle\n\nis here "
            + String(repeating: "and more after it ", count: 20)
        let snippet = SearchSnippet.make(body: body, query: query)
        XCTAssertTrue(snippet.hasPrefix("…"), snippet)
        XCTAssertTrue(snippet.hasSuffix("…"), snippet)
        XCTAssertTrue(snippet.contains("the <mark>needle</mark> is here"), snippet)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertLessThanOrEqual(snippet.count, SearchSnippet.windowLength + "<mark></mark>……".count)
    }

    /// The phrase wins the anchor over an earlier stray word.
    func test_snippet_anchorsOnThePhraseBeforeLooseWords() throws {
        let query = try XCTUnwrap(SearchQuery("time crisis"))
        let body = "time " + String(repeating: "padding ", count: 30) + "then time crisis appears"
        let snippet = SearchSnippet.make(body: body, query: query)
        XCTAssertTrue(snippet.contains("<mark>time crisis</mark>"), snippet)
    }

    func test_snippet_withNoLiteralMatch_showsTheStartUnmarked() throws {
        let query = try XCTUnwrap(SearchQuery("café"))
        XCTAssertEqual(SearchSnippet.make(body: "the cafe is open", query: query), "the cafe is open")
    }
}

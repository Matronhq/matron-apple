import XCTest
@testable import MatronDesignSystem

/// Voice mode's cleaner (spec 2026-10-03 §3): what a message sounds like
/// once everything that cannot be said is taken out.
final class SpeechCleanerTests: XCTestCase {
    // MARK: speakable

    func testPlainProseIsUnchanged() {
        XCTAssertEqual(SpeechCleaner.speakable("The build is green."), "The build is green.")
    }

    func testHeadingsAndListMarkersAreRemoved() {
        let body = """
        ## Next steps

        - Merge the branch
        - Deploy to **staging**
        1. Then tell Dan
        """
        XCTAssertEqual(SpeechCleaner.speakable(body),
                       "Next steps. Merge the branch. Deploy to staging. Then tell Dan.")
    }

    func testEmphasisAndInlineCodeKeepTheirWords() {
        XCTAssertEqual(SpeechCleaner.speakable("Run `make test` and it *should* pass."),
                       "Run make test and it should pass.")
    }

    func testACodeBlockBecomesOneNotice() {
        let body = "I changed the handler:\n\n```swift\nlet x = 1\nlet y = 2\n```\n\nIt works now."
        XCTAssertEqual(SpeechCleaner.speakable(body),
                       "I changed the handler. There's code in the chat. It works now.")
    }

    func testADiffBlockSaysDiff() {
        let body = "Here is the change.\n\n```diff\n- old\n+ new\n```"
        XCTAssertEqual(SpeechCleaner.speakable(body), "Here is the change. There's a diff in the chat.")
    }

    func testATableBecomesOneNoticeHoweverManyCells() {
        let body = """
        Timings:

        | Run | Seconds |
        |---|---|
        | 1 | 12 |
        | 2 | 14 |

        Both are fine.
        """
        XCTAssertEqual(SpeechCleaner.speakable(body), "Timings. There's a table in the chat. Both are fine.")
    }

    func testLinkTextIsKeptAndTheAddressDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("See [the pull request](https://github.com/Matronhq/matron-apple/pull/305) for more."),
                       "See the pull request for more.")
    }

    func testABareAddressIsDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("It is live at https://example.com/a/b?c=1 now."), "It is live at now.")
        XCTAssertEqual(SpeechCleaner.speakable("Docs: <https://example.com/docs>"), "Docs.")
    }

    func testImagesAreDropped() {
        XCTAssertEqual(SpeechCleaner.speakable("Before ![screenshot](https://example.com/a.png) after."), "Before after.")
    }

    func testAnItemLinkReadsAsTheItem() {
        XCTAssertEqual(SpeechCleaner.speakable("I filed [#12](matron://item/12) for the copy."),
                       "I filed item twelve for the copy.")
        XCTAssertEqual(SpeechCleaner.speakable("The steps are on matron://item/5685."),
                       "The steps are on item five thousand six hundred eighty-five.")
    }

    /// `[label]: text` is a link reference definition to CommonMark and
    /// renders as nothing; the bridge's voice-note mirror has that shape.
    func testALabelColonLineKeepsItsWords() {
        XCTAssertEqual(SpeechCleaner.speakable("[blocked]: waiting on Dan"), "[blocked]: waiting on Dan.")
    }

    func testABlockQuoteIsRead() {
        XCTAssertEqual(SpeechCleaner.speakable("The draft:\n\n> Dear parents, the books are late."),
                       "The draft. Dear parents, the books are late.")
    }

    func testAnEmptyOrCodeOnlyMessage() {
        XCTAssertEqual(SpeechCleaner.speakable(""), "")
        XCTAssertEqual(SpeechCleaner.speakable("```\nls\n```"), "There's code in the chat.")
    }

    // MARK: fallbackShort

    func testFallbackKeepsTheFirstTwoSentences() {
        let body = "The deploy finished. All 412 tests passed. The cache was rebuilt. Nothing else changed."
        XCTAssertEqual(SpeechCleaner.fallbackShort(body), "The deploy finished. All 412 tests passed.")
    }

    func testFallbackAddsAClosingQuestion() {
        let body = "The deploy finished. All tests passed. The cache was rebuilt. Shall I merge it now?"
        XCTAssertEqual(SpeechCleaner.fallbackShort(body),
                       "The deploy finished. All tests passed. Shall I merge it now?")
    }

    func testFallbackDoesNotRepeatAQuestionAlreadyInTheFirstTwo() {
        XCTAssertEqual(SpeechCleaner.fallbackShort("It failed. Shall I retry?"), "It failed. Shall I retry?")
    }

    func testFallbackSkipsHeadingsAndUnsayableBlocks() {
        let body = "# Report\n\n```\nlog\n```\n\nThe job failed on step three. I have not retried it."
        XCTAssertEqual(SpeechCleaner.fallbackShort(body),
                       "There's code in the chat. The job failed on step three.")
    }

    func testFallbackStaysUnderTheContractCap() {
        let long = String(repeating: "word ", count: 120) + "end. Second sentence."
        XCTAssertLessThanOrEqual(SpeechCleaner.fallbackShort(long).count, SpeechCleaner.shortLimit)
        XCTAssertFalse(SpeechCleaner.fallbackShort(long).isEmpty)
    }

    func testFallbackOfNothingIsEmpty() {
        XCTAssertEqual(SpeechCleaner.fallbackShort("   "), "")
    }

    // MARK: sections

    func testAShortMessageIsOneSection() {
        XCTAssertEqual(SpeechCleaner.sections("One. Two."), ["One. Two."])
    }

    func testAHeadingStartsANewSection() {
        let body = "Intro paragraph.\n\n## Risks\n\nIt may be slow.\n\n## Plan\n\nShip on Monday."
        XCTAssertEqual(SpeechCleaner.sections(body),
                       ["Intro paragraph.", "Risks. It may be slow.", "Plan. Ship on Monday."])
    }

    func testParagraphsFillASectionUpToTheLimit() {
        let body = "one two three.\n\nfour five six.\n\nseven eight nine."
        XCTAssertEqual(SpeechCleaner.sections(body, wordsPerSection: 6),
                       ["one two three. four five six.", "seven eight nine."])
    }

    func testALongParagraphIsCutAtSentences() {
        let body = "Alpha beta gamma. Delta epsilon zeta. Eta theta iota."
        XCTAssertEqual(SpeechCleaner.sections(body, wordsPerSection: 4),
                       ["Alpha beta gamma.", "Delta epsilon zeta.", "Eta theta iota."])
    }

    func testSectionsOfNothing() {
        XCTAssertEqual(SpeechCleaner.sections(""), [])
    }

    func testSpelledNumbers() {
        XCTAssertEqual(SpeechCleaner.spelled(1), "one")
        XCTAssertEqual(SpeechCleaner.spelled(21), "twenty-one")
    }
}

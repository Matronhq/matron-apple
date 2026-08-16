import XCTest
import MatronJournal
@testable import MatronChat

final class SessionTagTests: XCTestCase {

    // MARK: splitTitle — peeling the bridge's `[bc] ` prefix

    func testSplitTitlePeelsASessionShort() {
        let (short, title) = SessionTag.splitTitle("[b5] css token migration")
        XCTAssertEqual(short, "b5")
        XCTAssertEqual(title, "css token migration")
    }

    func testSplitTitleLeavesUnprefixedTitlesAlone() {
        for raw in [
            "css token migration",         // no prefix at all
            "[b5]no space after bracket",
            "[b5f] three chars is not a short",
            "[b] one char is not a short",
            "[b ] spaces are not a short",
            "[b5] ",                       // nothing after the prefix
            "",
        ] {
            let (short, title) = SessionTag.splitTitle(raw)
            XCTAssertNil(short, "expected no short in \(raw)")
            XCTAssertEqual(title, raw, "title must come back unchanged for \(raw)")
        }
    }

    func testSplitTitleTakesOnlyTheFirstPrefix() {
        // A user message that itself starts with a bracketed pair stays
        // part of the visible title.
        let (short, title) = SessionTag.splitTitle("[f0] [ok] do the thing")
        XCTAssertEqual(short, "f0")
        XCTAssertEqual(title, "[ok] do the thing")
    }

    func testSplitTitlePeelsARoomShortBehindTheLinkMarker() {
        // Agent-chat room titles (bridge #225): the room short sits BEHIND
        // the 🔗 marker, which stays with the title — a single-box user
        // gets no styled tag but must keep the room marker.
        let (short, title) = SessionTag.splitTitle("🔗 [ab] mac ↔ dev-z — ci triage")
        XCTAssertEqual(short, "ab")
        XCTAssertEqual(title, "🔗 mac ↔ dev-z — ci triage")

        // A 🔗 title with no short behind it comes back untouched.
        let (none, plain) = SessionTag.splitTitle("🔗 mac ↔ dev-z")
        XCTAssertNil(none)
        XCTAssertEqual(plain, "🔗 mac ↔ dev-z")
    }

    func testTitleBesideRoomTagDropsTheMarker() {
        XCTAssertEqual(SessionTag.titleBesideRoomTag("🔗 mac ↔ dev-z"), "mac ↔ dev-z")
        XCTAssertEqual(SessionTag.titleBesideRoomTag("mac ↔ dev-z"), "mac ↔ dev-z")
    }

    // MARK: boxLetters — one distinguishing letter per box

    func testLettersStripTheCommonPrefix() {
        // The colleague-with-two-DEV-boxes problem: dev-y / dev-z must
        // come out Y / Z, not both D.
        let letters = SessionTag.boxLetters(for: [1: "dev-y", 2: "dev-z"])
        XCTAssertEqual(letters[1], "Y")
        XCTAssertEqual(letters[2], "Z")
    }

    func testLettersKeepInitialsForUnrelatedNames() {
        let letters = SessionTag.boxLetters(for: [1: "mac-mini", 2: "dev-3"])
        XCTAssertEqual(letters[1], "M")
        XCTAssertEqual(letters[2], "D")
    }

    func testANameThatIsTheCommonPrefixFallsBackToItsInitial() {
        let letters = SessionTag.boxLetters(for: [1: "dev", 2: "dev-2"])
        XCTAssertEqual(letters[1], "D")
        XCTAssertEqual(letters[2], "2")
    }

    func testPrefixStripIsCaseInsensitive() {
        let letters = SessionTag.boxLetters(for: [1: "Dev-y", 2: "dev-z"])
        XCTAssertEqual(letters[1], "Y")
        XCTAssertEqual(letters[2], "Z")
    }

    func testAnExpandingUppercaseMappingStaysOneCharacter() {
        // `ß`.uppercased() is "SS" — the tag is one character by contract,
        // so an expanding mapping keeps the original letter instead.
        let letters = SessionTag.boxLetters(for: [1: "box-ß", 2: "box-z"])
        XCTAssertEqual(letters[1], "ß")
        XCTAssertEqual(letters[2], "Z")
    }

    func testSingleBoxKeepsItsInitial() {
        XCTAssertEqual(SessionTag.boxLetters(for: [1: "mac-mini"]), [1: "M"])
    }

    func testEmptyRegistryYieldsNoLetters() {
        XCTAssertEqual(SessionTag.boxLetters(for: [:]), [:])
    }

    // MARK: summary integration — the fields rows actually consume

    func testSummaryStripsTheShortAndGatesTheLetter() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:dan")
        try store.applyColdSnapshot([
            ConvoSummaryDTO(id: "c1", title: "[b5] css token migration", sessionState: "running",
                            lastSeq: 1, snippet: "", createdAt: 1, agentDeviceID: 7),
        ], headSeq: 1)
        let record = try XCTUnwrap(store.conversation(id: "c1"))

        // Two boxes: title is cleaned, short peeled, letter derived.
        let two: [Int64: String] = [7: "dev-y", 9: "dev-z"]
        let tagged = JournalChatService.summary(from: record, boxNames: two,
                                                boxLetters: SessionTag.boxLetters(for: two))
        XCTAssertEqual(tagged.title, "css token migration")
        XCTAssertEqual(tagged.sessionShort, "b5")
        XCTAssertEqual(tagged.boxShort, "Y")

        // One box: the session short still shows (it tells SESSIONS apart),
        // but the letter obeys the chip gate.
        let solo = JournalChatService.summary(from: record, boxNames: [7: "dev-y"],
                                              boxLetters: SessionTag.boxLetters(for: [7: "dev-y"]))
        XCTAssertEqual(solo.sessionShort, "b5")
        XCTAssertNil(solo.boxShort)
        XCTAssertNil(solo.boxName)
    }
}

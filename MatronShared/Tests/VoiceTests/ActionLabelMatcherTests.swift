import XCTest
@testable import MatronVoice

final class ActionLabelMatcherTests: XCTestCase {
    private func check(_ labels: [String], _ table: [(String, ActionMatch)], file: StaticString = #filePath, line: UInt = #line) {
        for (utterance, expected) in table {
            XCTAssertEqual(ActionLabelMatcher.match(utterance, labels: labels), expected,
                           "\u{201C}\(utterance)\u{201D} against \(labels)", file: file, line: line)
        }
    }

    func testTwoShortLabels() {
        check(["Go", "Wait"], [
            // Clear: the label, or the label with filler.
            ("go", .clear("Go")), ("Go.", .clear("Go")), ("Yes, go", .clear("Go")), ("go please", .clear("Go")),
            ("OK let's go", .clear("Go")), ("I'd say go", .clear("Go")), ("wait", .clear("Wait")),
            ("Let's wait.", .clear("Wait")), ("I think we should wait", .clear("Wait")),
            // Clear: by position.
            ("option one", .clear("Go")), ("Option two.", .clear("Wait")), ("the first one", .clear("Go")),
            ("the second one", .clear("Wait")), ("number two", .clear("Wait")), ("the last one", .clear("Wait")),
            ("I'll take the second", .clear("Wait")), ("second option please", .clear("Wait")),
            // Unsure: close to one, or close to two.
            ("go, after lunch", .unsure("Go")), ("go wait", .unsure("Go")), ("wait a minute", .unsure("Wait")),
            // None: a position that is not there, a refusal, a question, a sentence.
            ("option three", .none), ("the fourth one", .none), ("don't go", .none), ("not wait", .none),
            ("what does wait mean", .none), ("go but check the tests first", .none),
            ("why would we go now", .none), ("tell me about the risk", .none), ("", .none), ("yes", .none),
        ])
    }

    func testLongerLabels() {
        check(["Merge now", "Wait until Monday", "Close it"], [
            ("merge now", .clear("Merge now")), ("Merge it now.", .clear("Merge now")),
            ("yes merge now please", .clear("Merge now")), ("wait until Monday", .clear("Wait until Monday")),
            ("close it", .clear("Close it")), ("the third one", .clear("Close it")), ("the last one", .clear("Close it")),
            ("option 2", .clear("Wait until Monday")),
            // Part of a label, or a slip of one.
            ("merge", .unsure("Merge now")), ("Monday", .unsure("Wait until Monday")), ("close", .clear("Close it")),
            ("wait until Mondays", .unsure("Wait until Monday")), ("merge now on aspen", .unsure("Merge now")),
            ("don't merge now", .none), ("merge now unless the tests fail", .none), ("what about Tuesday", .none),
        ])
    }

    func testLabelsThatAreAlsoFillerOrCommands() {
        check(["Yes", "No"], [
            ("yes", .clear("Yes")), ("Yes please", .clear("Yes")), ("no", .clear("No")), ("No thanks.", .clear("No")),
            ("the first one", .clear("Yes")), ("okay", .none),
        ])
        check(["Skip", "Stop the run", "Go with option one"], [
            ("skip", .clear("Skip")), ("stop the run", .clear("Stop the run")),
            ("go with option one", .clear("Go with option one")), ("option one", .clear("Skip")),
            ("stop", .unsure("Stop the run")),
        ])
    }

    func testEmojiAndPunctuationInLabelsDoNotMatter() {
        check(["⚡ Send all now", "🕓 Keep queued"], [
            ("send all now", .clear("⚡ Send all now")), ("keep queued", .clear("🕓 Keep queued")),
            ("send all", .unsure("⚡ Send all now")),
        ])
    }

    func testNoLabelsMeansNoMatch() {
        XCTAssertEqual(ActionLabelMatcher.match("go", labels: []), .none)
    }

    func testPermissionVerdicts() {
        let table: [(String, ActionLabelMatcher.PermissionVerdict?)] = [
            ("allow", .allow), ("Allow it.", .allow), ("yes", .allow), ("OK", .allow), ("go ahead", .allow),
            ("allow once please", .allow), ("yes, allow it", .allow), ("approve", .allow),
            ("always", .always), ("always allow", .always), ("Always allow it", .always),
            ("deny", .deny), ("Deny it.", .deny), ("no", .deny), ("don't", .deny), ("do not allow that", .deny),
            ("reject", .deny), ("no, deny it", .deny),
            ("what does it do", nil), ("allow it but only this once in the repo", nil), ("", nil), ("maybe", nil),
        ]
        for (utterance, expected) in table {
            XCTAssertEqual(ActionLabelMatcher.permissionVerdict(utterance), expected, "\u{201C}\(utterance)\u{201D}")
        }
    }

    func testSimilarity() {
        XCTAssertEqual(ActionLabelMatcher.similarity("postgres", "postgres"), 1)
        XCTAssertEqual(ActionLabelMatcher.similarity("postgress", "postgres"), 1 - 1.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(ActionLabelMatcher.similarity("", "go"), 0)
    }
}

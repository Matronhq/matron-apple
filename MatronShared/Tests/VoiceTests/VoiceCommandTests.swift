import XCTest
@testable import MatronVoice

final class VoiceCommandTests: XCTestCase {
    func testCommandTable() {
        let table: [(String, VoiceCommand?)] = [
            // repeat
            ("repeat", .repeat), ("Repeat that.", .repeat), ("Say that again", .repeat), ("again", .repeat),
            ("Sorry, what?", .repeat), ("Can you repeat that please?", .repeat), ("pardon", .repeat),
            // more
            ("more", .more), ("Tell me more.", .more), ("I want to know more", .more), ("Go on", .more),
            ("keep going", .more), ("More detail please", .more), ("um, carry on", .more), ("continue", .more),
            ("read the rest", .more),
            // skip / next
            ("skip", .skip), ("Next.", .skip), ("skip this one", .skip), ("next one please", .skip), ("move on", .skip),
            // stop
            ("stop", .stop), ("Stop talking", .stop), ("OK, stop.", .stop), ("that's enough", .stop),
            ("That\u{2019}s enough, thanks", .stop), ("be quiet", .stop),
            // cancel
            ("cancel", .cancel), ("Cancel that", .cancel), ("never mind", .cancel), ("Don't send that", .cancel),
            ("do not send it", .cancel),
            // yes / no
            ("yes", .yes), ("Yeah.", .yes), ("okay", .yes), ("OK", .yes), ("that's right", .yes), ("go ahead", .yes),
            ("yes please", .yes),
            ("no", .no), ("Nope", .no), ("no, wait", .no), ("No thanks", .no), ("that's wrong", .no),
            // not commands: a command with anything else is a message
            ("tell me more about the tests", nil), ("stop the deploy on bev", nil), ("next week is fine", nil),
            ("repeat the migration on staging", nil), ("yes, go with the second option", nil),
            ("no, use Postgres instead", nil), ("cancel the order for the school", nil),
            ("more or less", nil), ("skip the tests and merge", nil), ("", nil), ("   ", nil), ("please", nil),
        ]
        for (utterance, expected) in table {
            XCTAssertEqual(VoiceCommand.parse(utterance), expected, "\u{201C}\(utterance)\u{201D}")
        }
    }

    func testWordsNormalise() {
        XCTAssertEqual(VoiceText.words("That\u{2019}s RIGHT — go, now!"), ["thats", "right", "go", "now"])
        XCTAssertEqual(VoiceText.words("Don't  send #12 ✅"), ["dont", "send", "12"])
        XCTAssertEqual(VoiceText.words(""), [])
    }
}

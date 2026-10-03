import XCTest
import MatronJournal
import MatronModels
@testable import MatronVoice

final class VoiceTypesTests: XCTestCase {
    private func promptEvent(_ payload: [String: Any], type: String = "prompt") -> JournalEvent {
        JournalEvent(seq: 9, convoID: "c1", ts: Date(timeIntervalSince1970: 1), sender: "agent:bev", type: type,
                     payloadData: try! JSONSerialization.data(withJSONObject: payload))
    }

    func testAskPromptDecodes() throws {
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "Which database?", "allows_free_text": true,
            "options": ["Postgres", ["id": "s", "label": "SQLite", "value": "sqlite"]],
        ])))
        XCTAssertEqual(prompt.seq, 9); XCTAssertEqual(prompt.convoID, "c1")
        XCTAssertEqual(prompt.labels, ["Postgres", "SQLite"])
        XCTAssertEqual(prompt.options.map(\.value), ["Postgres", "sqlite"])
        XCTAssertTrue(prompt.allowsFreeText); XCTAssertFalse(prompt.isPermission)
    }

    func testAPromptWithNoOptionsTakesFreeText() throws {
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent(["question": "What should the title be?"])))
        XCTAssertEqual(prompt.options, []); XCTAssertTrue(prompt.allowsFreeText)
    }

    func testOnlyAPromptRowIsAPrompt() {
        XCTAssertNil(VoicePrompt(event: promptEvent(["body": "hi"], type: "text")))
    }

    /// Ordinary buttons whose values merely start with `perm` are not a
    /// permission card.
    func testPermissionNeedsTheBridgesButtonValues() throws {
        let fake = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "Permission to proceed?",
            "options": [["id": "a", "label": "Allow", "value": "perm:allow"], ["id": "b", "label": "Deny", "value": "perm:deny"]],
        ])))
        XCTAssertFalse(fake.isPermission)
    }

    func testPermissionDetailIsCutAtEightyCharacters() throws {
        let id = NeedsYouQueueTests.permissionID
        let long = String(repeating: "x", count: 200)
        let prompt = try XCTUnwrap(VoicePrompt(event: promptEvent([
            "question": "🔐 Permission: Claude wants to run Bash\n\(long)",
            "options": [["id": "a", "label": "Allow once", "value": "perm:\(id):allow"],
                        ["id": "d", "label": "Deny", "value": "perm:\(id):deny"]],
        ])))
        XCTAssertEqual(prompt.permission?.detail.count, 80)
    }

    func testItemNeedsTheScreenForSecretsAndConsent() {
        func item(labels: [String] = [], links: [TrackerLink] = []) -> TrackerItem {
            TrackerItem(id: "it_1", num: 1, kind: .question, awaiting: .user, title: "T", labels: labels, links: links,
                        originConvoID: "c1", actions: ["Go"])
        }
        XCTAssertFalse(VoiceItem.needsScreen(item()))
        XCTAssertTrue(VoiceItem.needsScreen(item(labels: ["secret"])))
        XCTAssertTrue(VoiceItem.needsScreen(item(labels: ["consent"])))
        XCTAssertTrue(VoiceItem.needsScreen(item(links: [TrackerLink(url: "matron://consent/spawn/req_1")])))
        let voice = VoiceItem(item(labels: ["secret"]), sections: [])
        XCTAssertEqual(VoiceEntry.item(voice, convoTitle: "T").labels, [], "nothing to tap for a screen-only item")
        XCTAssertEqual(VoiceItem(item(), sections: ["Body."]).labels, ["Go"])
    }

    func testPhrases() {
        XCTAssertEqual(VoicePhrases.needsYou(0), "Nothing needs you.")
        XCTAssertEqual(VoicePhrases.needsYou(1), "One thing needs you.")
        XCTAssertEqual(VoicePhrases.needsYou(3), "Three things need you.")
        XCTAssertEqual(VoicePhrases.needsYou(21), "Twenty-one things need you.")
        XCTAssertEqual(VoicePhrases.sending("Go"), "Sending: Go.")
        XCTAssertEqual(VoicePhrases.didYouMean("Allow once"), "Did you mean Allow once?")
        XCTAssertEqual(VoicePhrases.busy("bev"), "bev is busy. It will get this when it finishes.")
        XCTAssertEqual(VoicePhrases.busy(nil), "The agent is busy. It will get this when it finishes.")
        XCTAssertEqual(VoicePhrases.options(["Go", "Wait"]), "Options: Go, Wait.")
        XCTAssertTrue(VoicePhrases.fixed.contains("Three things need you."))
        XCTAssertEqual(VoicePhrases.couldNotHear, "I couldn't hear you, so I haven't sent that.")
        XCTAssertTrue(VoicePhrases.fixed.contains(VoicePhrases.couldNotHear))
    }

    /// A whole-utterance command said over a clip is taken for the clip's
    /// own words when the clip contains it (`VoiceModeEngine.isEcho`), and
    /// ignored. So nothing the engine says by itself may contain a command,
    /// in ANY phrasing the parser accepts: "Say more for the detail." made
    /// "more" fail on exactly the replies that taught it, "Ask for the
    /// detail if you want it." did the same to "the detail", and "Go on?"
    /// was itself the command "go on".
    ///
    /// The phrasings are read from `VoiceCommand.phrases`, the table the
    /// parser is built from, so this cannot drift from the parser.
    func testNoFixedPhraseContainsACommandPhrasing() {
        // Every phrasing, and proof that the list is the parser's own.
        var phrasings: [String] = []
        for (command, list) in VoiceCommand.phrases {
            for phrasing in list {
                XCTAssertEqual(VoiceCommand.parse(phrasing), command, phrasing)
                phrasings.append(phrasing)
            }
        }
        XCTAssertEqual(Set(VoiceCommand.phrases.keys), Set(VoiceCommand.allCases))
        XCTAssertGreaterThan(phrasings.count, 90)

        // The phrases that keep one, each with why that is harmless. All
        // are negatives or acknowledgements: none is a way to ask for
        // something that would then be swallowed.
        let allowed: [String: Set<String>] = [
            // "No connection. …" (both) and "There's no conversation to
            // send that to.": "no" is a command only as the answer to a
            // question the engine asked (a confirmation, or "Keep going?"),
            // and its only effect there is not to send or not to go on.
            // Over one of these clips it waits until the clip ends;
            // "cancel" and a tap are not affected.
            VoicePhrases.noConnection: ["no"],
            VoicePhrases.notSentOffline: ["no"],
            VoicePhrases.nowhereToSend: ["no"],
            // "There's nothing to repeat." answers "repeat" when there is
            // nothing to say again: "repeat" over it would only produce
            // the same sentence.
            VoicePhrases.nothingToRepeat: ["repeat"],
            // "OK, not sent." follows a confirmation that was just turned
            // down. "ok" is a yes-word, and yes is a command only while a
            // question is open; this clip is said after it has closed, so
            // "ok" over it has nothing to confirm.
            VoicePhrases.notSent: ["ok"],
        ]

        // Everything the engine says by itself: the fixed lines, and the
        // templates with a label and a box name that are no command.
        let templates = [
            VoicePhrases.sending("Blue"), VoicePhrases.didYouMean("Blue"), VoicePhrases.busy("bev"), VoicePhrases.busy(nil),
            VoicePhrases.options(["Blue", "Green"]),
            VoicePhrases.prompt(VoicePrompt(convoID: "c1", seq: 1, question: "",
                                            permission: .init(tool: "Bash", detail: "ls")), boxName: "bev"),
            VoicePhrases.prompt(VoicePrompt(convoID: "c1", seq: 1, question: "",
                                            permission: .init(tool: "Edit", detail: "")), boxName: nil),
        ]
        XCTAssertTrue(VoicePhrases.fixed.contains(VoicePhrases.moreHint))
        XCTAssertTrue(VoicePhrases.fixed.contains(VoicePhrases.goOn))
        for phrase in VoicePhrases.fixed + templates {
            XCTAssertNil(VoiceCommand.parse(phrase), "\u{201C}\(phrase)\u{201D} is itself a command")
            // Contiguous words, lowercase, punctuation gone: the same
            // comparison the engine makes when it decides what is an echo.
            let found = Set(phrasings.filter { VoiceModeEngine.isEcho($0, of: phrase) })
            XCTAssertEqual(found, allowed[phrase] ?? [], "\u{201C}\(phrase)\u{201D}")
        }
        for phrase in allowed.keys {
            XCTAssertTrue(VoicePhrases.fixed.contains(phrase), "allow-listed but never said: \(phrase)")
        }
        XCTAssertEqual(VoicePhrases.moreHint, "I can go deeper if you like.")
        XCTAssertEqual(VoicePhrases.goOn, "Keep going?")
    }

    func testReadings() {
        let reply = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 5, short: "The deploy finished."), convoTitle: "Auth refactor")
        XCTAssertEqual(VoicePhrases.reading(reply, inQueue: false), "The deploy finished.")
        XCTAssertEqual(VoicePhrases.reading(reply, inQueue: true), "Auth refactor. The deploy finished.")

        let item = VoiceEntry.item(VoiceItem(id: "it_1", kind: .decision, convoID: "c1", title: "Ship the promo page",
                                             labels: ["Go", "Wait"]), convoTitle: "Promo")
        XCTAssertEqual(VoicePhrases.reading(item, inQueue: true), "A decision: Ship the promo page. Options: Go, Wait.")
        let secret = VoiceEntry.item(VoiceItem(id: "it_2", kind: .question, convoID: "c1", title: "AWS key", needsScreen: true),
                                     convoTitle: "Promo")
        XCTAssertEqual(VoicePhrases.reading(secret, inQueue: true), "That one needs the screen. It's in your tracker.")

        let ask = VoiceEntry.prompt(VoicePrompt(convoID: "c1", seq: 9, question: "Which database?",
                                                options: [.init(label: "Postgres", value: "p"), .init(label: "SQLite", value: "s")]),
                                    convoTitle: "Auth refactor", boxName: "bev")
        XCTAssertEqual(VoicePhrases.reading(ask, inQueue: false), "Which database? Options: Postgres, SQLite.")
        XCTAssertEqual(VoicePhrases.reading(ask, inQueue: true), "Auth refactor. Which database? Options: Postgres, SQLite.")

        let permission = VoicePrompt(convoID: "c1", seq: 10, question: "", options: [],
                                     permission: .init(tool: "Bash", detail: "git push origin main"))
        XCTAssertEqual(VoicePhrases.reading(.prompt(permission, convoTitle: "Auth refactor", boxName: "bev"), inQueue: false),
                       "bev wants to run a command: git push origin main. Allow or deny?")
        XCTAssertEqual(VoicePhrases.reading(.prompt(permission, convoTitle: "Auth refactor", boxName: "bev"), inQueue: true),
                       "In Auth refactor. bev wants to run a command: git push origin main. Allow or deny?")
        let edit = VoicePrompt(convoID: "c1", seq: 11, question: "", permission: .init(tool: "Edit", detail: ""))
        XCTAssertEqual(VoicePhrases.reading(.prompt(edit, convoTitle: "", boxName: nil), inQueue: true),
                       "The agent wants to use Edit. Allow or deny?")
    }
}

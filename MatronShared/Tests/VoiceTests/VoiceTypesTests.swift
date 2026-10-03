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
    }

    /// A whole-utterance command said over a clip is taken for the clip's
    /// own words when the clip contains it (`VoiceModeEngine.isEcho`), and
    /// ignored. So nothing the engine says by itself may contain one of
    /// the command words: "Say more for the detail." made "more" fail on
    /// exactly the replies that taught it.
    func testNoFixedPhraseContainsACommandWord() {
        let commandWords: Set<String> = ["more", "repeat", "skip", "next", "stop", "cancel", "yes", "no"]
        // Phrases that keep a command word, each with why that is harmless.
        let allowed: [String: Set<String>] = [
            // "No connection. …" and "There's no conversation …": "no" is a
            // command only as the answer to "Go on?" or to a confirmation,
            // and there its only effect is not to go on or not to send. Over
            // one of these clips it is ignored until the clip ends; "cancel"
            // and a tap are not affected.
            VoicePhrases.noConnection: ["no"],
            VoicePhrases.notSentOffline: ["no"],
            VoicePhrases.nowhereToSend: ["no"],
            // "There's nothing to repeat." is the answer to "repeat" when
            // there is nothing to say again: "repeat" said over it would
            // only produce the same sentence.
            VoicePhrases.nothingToRepeat: ["repeat"],
        ]
        XCTAssertTrue(VoicePhrases.fixed.contains(VoicePhrases.moreHint))
        XCTAssertTrue(VoicePhrases.fixed.contains(VoicePhrases.goOn))
        for phrase in VoicePhrases.fixed {
            let found = commandWords.intersection(VoiceText.words(phrase))
            XCTAssertEqual(found, allowed[phrase] ?? [], "\u{201C}\(phrase)\u{201D}")
        }
        for phrase in allowed.keys {
            XCTAssertTrue(VoicePhrases.fixed.contains(phrase), "allow-listed but never said: \(phrase)")
        }
        XCTAssertEqual(VoicePhrases.moreHint, "Ask for the detail if you want it.")
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

import XCTest
@testable import MatronVoice
@testable import Matron

/// Voice mode on a car's display: what the voice-control screen is given
/// for each engine state. The car's rules are the point of most of these:
/// no reply text, at most two buttons, at most twelve rows.
final class CarPlayVoiceScreenTests: XCTestCase {
    typealias Screen = CarPlayVoiceScreen

    private func state(_ phase: VoiceModeEngine.Phase) -> VoiceModeEngine.State {
        var state = VoiceModeEngine.State()
        state.phase = phase
        state.convoID = "c1"
        state.convoTitle = "Auth refactor"
        state.boxName = "box-a"
        return state
    }

    private static let item = VoiceEntry.item(
        VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship the promo page", labels: ["Go", "Wait"]),
        convoTitle: "Promo", boxName: "box-b")
    private static let reply = VoiceEntry.reply(
        SpokenReply(convoID: "c1", seq: 10, short: "The deploy finished. Shall I merge?"),
        convoTitle: "Auth refactor", boxName: "box-a")

    // MARK: Which state shows

    func test_eachEnginePhaseHasAState() {
        XCTAssertEqual(Screen.model(state(.listening)).active, .listening)
        XCTAssertEqual(Screen.model(state(.sending)).active, .sending)
        XCTAssertEqual(Screen.model(state(.speaking)).active, .speaking)
        XCTAssertEqual(Screen.model(state(.waiting)).active, .ready)
        XCTAssertEqual(Screen.model(state(.confirming)).active, .listening, "the microphone is open for yes or no")
        var working = state(.waiting)
        working.working = ["c1"]
        XCTAssertEqual(Screen.model(working).active, .working)
    }

    func test_theTemplateIsNeverGivenMoreStatesThanItTakes() {
        XCTAssertLessThanOrEqual(Screen.StateID.allCases.count, 5)
        let model = Screen.model(state(.listening))
        XCTAssertEqual(Set(model.layout.titles.keys), Set(Screen.StateID.allCases))
    }

    // MARK: What is written on the display

    func test_titlesNameTheConversationAndTheBox_shortestFirst() {
        let titles = Screen.model(state(.listening)).layout.titles
        XCTAssertEqual(titles[.listening], ["Listening", "Listening: Auth refactor"])
        XCTAssertEqual(titles[.working], ["Working", "box-a is working"])
        XCTAssertEqual(titles[.speaking], ["Speaking", "box-a is speaking"])
        XCTAssertEqual(titles[.sending], ["Sending"])
    }

    func test_whatIsBeingSaidNeverReachesTheDisplay() {
        var speaking = state(.speaking)
        speaking.current = Self.reply
        speaking.caption = "The deploy finished. Shall I merge?"
        speaking.playing = VoiceModeEngine.Utterance(id: 1, text: "The deploy finished. Shall I merge?", level: .short)
        let model = Screen.model(speaking)
        let written = model.layout.titles.values.flatMap { $0 } + model.layout.buttons.values.flatMap { $0 }.map(\.title)
        for text in written {
            XCTAssertFalse(text.contains("deploy"), "\(text) shows reply text")
            XCTAssertFalse(text.contains("merge"), "\(text) shows reply text")
        }
    }

    func test_anItemsTitleIsSaidNotShown() {
        var speaking = state(.speaking)
        speaking.current = Self.item
        let model = Screen.model(speaking)
        let titles = model.layout.titles.values.flatMap { $0 }
        XCTAssertFalse(titles.contains { $0.contains("Ship the promo page") })
        XCTAssertEqual(model.layout.titles[.speaking], ["Speaking", "box-b is speaking"], "the thing being read names its own box")
    }

    // MARK: Buttons

    func test_twoAnswersBecomeTheTwoButtons() {
        var listening = state(.listening)
        listening.current = Self.item
        let buttons = Screen.model(listening).layout.buttons
        XCTAssertEqual(buttons[.listening], [.label("Go"), .label("Wait")])
        XCTAssertEqual(buttons[.speaking], [.label("Go"), .label("Wait")])
        XCTAssertEqual(Screen.Button.label("Go").event, .actionTapped("Go"))
    }

    func test_anyOtherNumberOfAnswersIsGivenByVoice_theButtonsAreSkipAndStop() {
        for labels in [[], ["Go"], ["A", "B", "C"], ["A", "B", "C", "D"]] {
            var listening = state(.listening)
            listening.current = .item(VoiceItem(id: "it_2", kind: .question, convoID: "c2", title: "T", labels: labels),
                                      convoTitle: "Promo")
            XCTAssertEqual(Screen.model(listening).layout.buttons[.listening], [.skip, .stop], "\(labels)")
        }
    }

    func test_withNothingBeingReadThereIsNothingToSkip() {
        XCTAssertEqual(Screen.model(state(.listening)).layout.buttons[.listening], [.stop])
    }

    func test_aPendingSendOffersOnlyCancel() {
        var confirming = state(.speaking)
        confirming.current = Self.item
        confirming.confirm = VoiceModeEngine.Confirm(kind: .sending, label: "Go",
                                                     send: .sendItemAction(itemID: "it_1", label: "Go"))
        XCTAssertEqual(Screen.model(confirming).layout.buttons[.speaking], [.cancel])
        XCTAssertEqual(Screen.Button.cancel.event, .tap)
    }

    func test_withTheMicrophoneClosedTheButtonOpensIt() {
        let buttons = Screen.model(state(.waiting)).layout.buttons
        XCTAssertEqual(buttons[.ready], [.talk])
        XCTAssertEqual(buttons[.working], [.talk])
        XCTAssertEqual(buttons[.sending], [])
        XCTAssertEqual(Screen.Button.talk.event, .tap)
        XCTAssertEqual(Screen.Button.skip.event, .commandTapped(.skip))
        XCTAssertEqual(Screen.Button.stop.event, .commandTapped(.stop))
    }

    func test_noStateIsEverGivenMoreThanTwoButtons() {
        var listening = state(.listening)
        listening.current = Self.item
        for model in [Screen.model(listening), Screen.model(state(.waiting)), Screen.model(.ready), Screen.model(.signedOut)] {
            for buttons in model.layout.buttons.values { XCTAssertLessThanOrEqual(buttons.count, Screen.buttonLimit) }
        }
    }

    // MARK: No sitting

    func test_withNoSittingTheScreenSaysWhy() {
        XCTAssertEqual(Screen.model(.ready).active, .ready)
        XCTAssertEqual(Screen.model(.ready).layout.buttons[.ready], [.talk])
        XCTAssertEqual(Screen.model(.signedOut).layout.titles[.ready]?.first, "Sign in on iPhone")
        XCTAssertEqual(Screen.model(.signedOut).layout.buttons[.ready], [])
        XCTAssertEqual(Screen.model(.microphoneBusy).layout.titles[.ready]?.first, "In use on iPhone")
        XCTAssertEqual(Screen.model(.microphoneBusy).layout.buttons[.ready], [.talk], "Talk tries again")
        XCTAssertEqual(Screen.model(.unavailable).layout.buttons[.ready], [])
    }

    // MARK: The conversation list

    func test_theListHoldsAtMostTwelveRows_inTheOrderGiven() {
        let conversations = (1...20).map {
            QueueConversation(id: "c\($0)", title: "Chat \($0)", boxName: "box-a", unreadCount: 0, sessionState: "waiting")
        }
        let rows = CarPlayChats.rows(conversations)
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(rows.first?.id, "c1")
        XCTAssertEqual(rows.last?.id, "c12")
    }

    func test_aRowShowsTheTitleWithoutItsSessionTag_theBox_andWhetherItIsWorking() {
        let rows = CarPlayChats.rows([
            QueueConversation(id: "c1", title: "[ab] Auth refactor", boxName: "box-a", unreadCount: 0, sessionState: "running"),
            QueueConversation(id: "c2", title: "Promo", boxName: nil, unreadCount: 3, sessionState: "waiting"),
            QueueConversation(id: "c3", title: "", boxName: "box-b", unreadCount: 0, sessionState: "done"),
        ])
        XCTAssertEqual(rows.map(\.title), ["Auth refactor", "Promo", "Conversation"])
        XCTAssertEqual(rows.map(\.detail), ["box-a · Working", nil, "box-b"])
    }
}

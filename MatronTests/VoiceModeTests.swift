import XCTest
import MatronDesignSystem
import MatronVoice
@testable import Matron

/// Voice mode on the iPhone (spec 2026-10-03 §6): the rules the shell and
/// the chat toolbar follow, and how engine state reaches the screen.
@MainActor
final class VoiceModeTests: XCTestCase {
    // MARK: Entry points

    func test_openVoiceMode_setsTheEntry_andASecondOpenIsIgnored() {
        let nav = AppShellNavigation()
        XCTAssertNil(nav.voiceMode)
        nav.openVoiceMode(.queue)
        XCTAssertEqual(nav.voiceMode, .queue)
        nav.openVoiceMode(.conversation(id: "c1", title: "Auth refactor", boxName: "aspen"))
        XCTAssertEqual(nav.voiceMode, .queue, "one sitting at a time")
        nav.closeVoiceMode()
        XCTAssertNil(nav.voiceMode)
    }

    func test_openingVoiceMode_leavesTabsAndStacksAlone() {
        let nav = AppShellNavigation()
        nav.tab = .decisions
        nav.chatPath = ["c1"]
        nav.openVoiceMode(.conversation(id: "c1", title: "T", boxName: nil))
        XCTAssertEqual(nav.tab, .decisions)
        XCTAssertEqual(nav.chatPath, ["c1"])
    }

    func test_entryIdentity() {
        XCTAssertEqual(VoiceModeEntry.queue.id, "queue")
        XCTAssertEqual(VoiceModeEntry.conversation(id: "c1", title: "T", boxName: nil).id, "conversation:c1")
    }

    func test_theChatToolbarOffersVoiceModeOnlyOnTheChatPage_andOnlyWhereItCanRun() {
        XCTAssertTrue(ChatView.showsVoiceModeTool(canOpen: true, page: .chat))
        XCTAssertFalse(ChatView.showsVoiceModeTool(canOpen: true, page: .tasks))
        XCTAssertFalse(ChatView.showsVoiceModeTool(canOpen: false, page: .chat))
    }

    // MARK: Screen mapping

    func test_engineStateMapsOntoTheScreen() {
        var state = VoiceModeEngine.State()
        state.convoTitle = "Auth refactor"
        state.boxName = "aspen"
        state.convoID = "c1"
        state.phase = .waiting
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 0),
                       VoiceModeScreen.Model(title: "Auth refactor", boxName: "aspen", phase: .waiting))
        state.working = ["c1"]
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 2).phase, .working)
        XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 2).unsentCount, 2)
        state.phase = .speaking
        state.caption = "Sending: Go."
        state.current = .item(VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship it", labels: ["Go", "Wait"]),
                              convoTitle: "Promo", boxName: "pat")
        let model = VoiceModeScreenMapping.model(state, unsentCount: 0)
        XCTAssertEqual(model.phase, .speaking)
        XCTAssertEqual(model.title, "Promo", "the thing being read names its own conversation")
        XCTAssertEqual(model.boxName, "pat")
        XCTAssertEqual(model.labels, ["Go", "Wait"])
        XCTAssertEqual(model.caption, "Sending: Go.")
        for (phase, expected) in [(VoiceModeEngine.Phase.listening, VoiceModeScreen.Model.Phase.listening),
                                  (.sending, .sending), (.confirming, .confirming)] {
            state.phase = phase
            XCTAssertEqual(VoiceModeScreenMapping.model(state, unsentCount: 0).phase, expected)
        }
    }

    // MARK: Confirmations on the screen

    /// Runs the engine itself, so the states are ones it really reaches.
    private func confirmingState(entry: VoiceEntry, said: String) -> VoiceModeEngine.State {
        var state = VoiceModeEngine.State()
        func send(_ event: VoiceModeEngine.Event) { state = VoiceModeEngine.reduce(state, event).0 }
        send(.start(.queue(entries: [entry], lastConvoID: nil, lastTitle: "", lastBoxName: nil)))
        send(.playbackFinished(state.playing?.id ?? -1))        // read out: listening
        send(.words(said))
        send(.timerFired(.silence, token: state.timers[.silence] ?? -1))
        send(.transcript(said))                                 // the question is being asked
        send(.playbackFinished(state.playing?.id ?? -1))        // and has been
        return state
    }

    /// "Sending: Go" sends unless he says "cancel". The engine clears its
    /// caption when the clip ends; what is about to go stays on screen.
    func test_aSendWaitingForCancel_keepsWhatItIsSendingOnScreen() {
        let item = VoiceEntry.item(VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship it", labels: ["Go", "Wait"]),
                                   convoTitle: "Promo", boxName: "pat")
        let state = confirmingState(entry: item, said: "go")
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertNil(state.caption)
        let model = VoiceModeScreenMapping.model(state, unsentCount: 0)
        XCTAssertEqual(model.phase, .confirming)
        XCTAssertEqual(model.caption, "Sending: Go.")
        XCTAssertEqual(model.labels, ["Go", "Wait"])
    }

    /// "Did you mean Allow once?" sends on "yes" only. Drawn as a send in
    /// progress ("Say cancel to stop") it would read as if silence allowed
    /// the tool.
    func test_aDidYouMeanQuestion_isDrawnAsAQuestion_notAsASendInProgress() {
        let prompt = VoicePrompt(convoID: "c3", seq: 30, question: "Permission: Claude wants to run Bash",
                                 options: [.init(label: "Allow once", value: "perm:x:allow"),
                                           .init(label: "Deny", value: "perm:x:deny")],
                                 permission: .init(tool: "Bash", detail: "git push"))
        let state = confirmingState(entry: .prompt(prompt, convoTitle: "Deploy", boxName: "aspen"), said: "allow")
        XCTAssertEqual(state.phase, .confirming)
        let model = VoiceModeScreenMapping.model(state, unsentCount: 0)
        XCTAssertEqual(model.phase, .asking)
        XCTAssertEqual(model.caption, "Did you mean Allow once?")
    }

    // MARK: One microphone

    /// A voice note being recorded owns the audio session: voice mode's
    /// buttons go, rather than take the microphone from under the note.
    func test_voiceModeCannotOpen_whileAVoiceNoteIsBeingRecorded_orWhereItCannotRun() {
        XCTAssertTrue(VoiceModeAvailability.canOpen(supported: true, recordingVoiceNote: false))
        XCTAssertFalse(VoiceModeAvailability.canOpen(supported: true, recordingVoiceNote: true))
        XCTAssertFalse(VoiceModeAvailability.canOpen(supported: false, recordingVoiceNote: false))
        // Until it has been tried on a phone: the hidden switch, or a
        // Debug build.
        XCTAssertFalse(VoiceModeAvailability.isSwitchedOn(debug: false, debugTools: false))
        XCTAssertTrue(VoiceModeAvailability.isSwitchedOn(debug: false, debugTools: true))
        XCTAssertTrue(VoiceModeAvailability.isSwitchedOn(debug: true, debugTools: false))
    }

    func test_theCleanerReachesTheFeed() {
        XCTAssertEqual(VoiceTextMaker.cleaner.plain("Which **database**?"), "Which database?")
        XCTAssertEqual(VoiceTextMaker.cleaner.short("Done."), "Done.")
    }
}

import XCTest
import MatronModels
@testable import MatronVoice

/// The voice engine, event by event (spec 2026-10-03 §3, §4, §5, §11, §12).
/// No audio, no network, no clock: effects are values.
final class VoiceModeEngineTests: XCTestCase {
    typealias Engine = VoiceModeEngine
    typealias Effect = VoiceModeEngine.Effect

    // MARK: Fixtures

    static let permissionID = "0b6f4c3e-8a7d-4e21-9f2a-3c5d7e9a1b2c"

    static let reply = VoiceEntry.reply(
        SpokenReply(convoID: "c1", seq: 10, short: "The deploy finished. Shall I merge?",
                    more: "Every test passed and the cache was rebuilt.",
                    sections: ["Section one.", "Section two.", "Section three."]),
        convoTitle: "Auth refactor", boxName: "bev")
    static let plainReply = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 11, short: "Done."),
                                             convoTitle: "Auth refactor", boxName: "bev")
    static let item = VoiceEntry.item(
        VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship the promo page", labels: ["Go", "Wait"],
                  sections: ["The page is ready."]),
        convoTitle: "Promo", boxName: "pat")
    static let secret = VoiceEntry.item(
        VoiceItem(id: "it_2", kind: .question, convoID: "c2", title: "AWS key", needsScreen: true), convoTitle: "Promo")
    static let ask = VoiceEntry.prompt(
        VoicePrompt(convoID: "c3", seq: 30, question: "Which database?",
                    options: [.init(label: "Postgres", value: "pg"), .init(label: "SQLite", value: "lite")],
                    allowsFreeText: true),
        convoTitle: "Schema", boxName: "bev")
    static let permission = VoiceEntry.prompt(
        VoicePrompt(convoID: "c1", seq: 40, question: "",
                    options: [.init(label: "Allow once", value: "perm:\(permissionID):allow"),
                              .init(label: "Always allow Bash (session)", value: "perm:\(permissionID):always"),
                              .init(label: "Deny", value: "perm:\(permissionID):deny")],
                    permission: .init(tool: "Bash", detail: "git push origin main")),
        convoTitle: "Auth refactor", boxName: "bev")

    /// Feeds `events` in order; returns the final state and the effects of
    /// the LAST event.
    ///
    /// Timer tokens are kept out of the way here, so a test reads as what
    /// happens rather than as bookkeeping: `.timerFired(.silence)` (the
    /// token-less helper below) fires with whatever token that timer
    /// currently has, as a correct runner would, and the returned
    /// `.startTimer` effects have their token blanked to `anyToken`. The
    /// tests under "Timer tokens" call `Engine.reduce` themselves.
    func run(_ state: Engine.State = Engine.State(), _ events: Engine.Event...) -> (Engine.State, [Effect]) {
        var state = state
        var effects: [Effect] = []
        for event in events {
            var event = event
            if case .timerFired(let id, token: Engine.Event.currentToken) = event {
                // Not armed: a token the engine never issues, so it is ignored.
                event = .timerFired(id, token: state.timers[id] ?? Engine.Effect.anyToken)
            }
            (state, effects) = Engine.reduce(state, event)
            effects = effects.map { effect in
                if case .startTimer(let id, let interval, token: _) = effect { return .startTimer(id, interval) }
                return effect
            }
        }
        return (state, effects)
    }

    func started(config: Engine.Config = Engine.Config()) -> Engine.State {
        var state = Engine.State()
        state.config = config
        return run(state, .routeChanged("Speaker"),
                   .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev"))).0
    }

    /// In `waiting`, as after sending a message.
    func waiting(config: Engine.Config = Engine.Config()) -> Engine.State {
        run(started(config: config), .timerFired(.noSpeech)).0
    }

    /// `entry` has been read out and the engine is listening for an answer.
    func heard(_ entry: VoiceEntry, config: Engine.Config = Engine.Config()) -> Engine.State {
        let (state, _) = run(waiting(config: config), .arrived(entry))
        return run(state, .playbackFinished(state.playing!.id)).0
    }

    /// The user said `text` after `state` started listening; the engine
    /// is now `sending`.
    func said(_ text: String, in state: Engine.State) -> Engine.State {
        run(state, .speechStarted, .words(text), .speechEnded, .timerFired(.silence)).0
    }

    func utterance(_ state: Engine.State) -> String? { state.playing?.text }

    // MARK: Start

    func testStartingInAConversationListens() {
        let (state, effects) = run(Engine.State(), .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev")))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.title, "Auth refactor")
        XCTAssertEqual(effects, [
            .keepScreenAwake(true), .startTimer(.idle, 1_800), .watch(convoID: "c1"), .activateAudio,
            .earcon(.micOpen), .startCapture(.record), .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120),
        ])
    }

    func testStartingTwiceIsIgnored() {
        let state = started()
        let (again, effects) = run(state, .start(.conversation(id: "c9", title: "Other", boxName: nil)))
        XCTAssertEqual(again, state)
        XCTAssertEqual(effects, [])
    }

    func testEventsBeforeStartDoNothing() {
        let (state, effects) = run(Engine.State(), .tap, .speechStarted, .words("hello"), .timerFired(.silence), .arrived(Self.reply))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(effects, [])
    }

    // MARK: Listening and sending

    func testNothingSaidForEightSecondsClosesTheMicrophone() {
        let (state, effects) = run(started(), .timerFired(.noSpeech))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .stopCapture(keep: false), .releaseAudio])
        XCTAssertFalse(state.audioActive)
    }

    func testSpeechThenSilenceEndsTheUtteranceAndUploadsIt() {
        var (state, effects) = run(started(), .speechStarted)
        XCTAssertEqual(effects, [.cancelTimer(.noSpeech)])
        (state, effects) = run(state, .words("merge it when the tests pass"), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 1.5)])
        // He carries on: the count starts again.
        (state, effects) = run(state, .speechStarted)
        XCTAssertEqual(effects, [.cancelTimer(.silence)])
        (state, effects) = run(state, .speechEnded, .timerFired(.silence))
        XCTAssertEqual(state.phase, .sending)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .startTimer(.idle, 1_800), .stopCapture(keep: true), .upload,
                                 .startTimer(.transcript, 8)])
    }

    func testTheSendButtonAndTheTwoMinuteLimitEndTheUtteranceToo() {
        XCTAssertEqual(run(started(), .speechStarted, .sendTapped).0.phase, .sending)
        XCTAssertEqual(run(started(), .speechStarted, .timerFired(.maxUtterance)).0.phase, .sending)
    }

    /// The detector may say nothing at all: words alone start the count.
    func testWordsWithoutADetectorEventStillEndTheUtterance() {
        let (state, effects) = run(started(), .words("hello there"))
        XCTAssertEqual(effects, [.cancelTimer(.noSpeech), .startTimer(.silence, 1.5)])
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .sending)
    }

    func testATranscriptThatAnswersNothingIsSentAsAVoiceNote() {
        let (state, effects) = run(said("merge it when the tests pass", in: started()), .transcript("Merge it when the tests pass."))
        XCTAssertEqual(effects, [.cancelTimer(.transcript), .sendVoiceNote(.conversation("c1")), .earcon(.sent), .releaseAudio])
        XCTAssertEqual(state.phase, .waiting)
    }

    /// Spec §3: no transcript within eight seconds, or none at all: an
    /// ordinary voice note, and the engine says "Sent".
    func testNoTranscriptSendsAPlainVoiceNoteAndSaysSent() {
        for event in [Engine.Event.timerFired(.transcript), .transcript(nil), .transcript("  ")] {
            let (state, effects) = run(said("hello", in: heard(Self.item)), event)
            XCTAssertTrue(effects.contains(.sendVoiceNote(.item("it_1"))), "\(event): option matching is skipped")
            XCTAssertEqual(utterance(state), "Sent.")
            XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        }
    }

    func testTheAgentBeingBusyIsSaid() {
        let (state, _) = run(said("and another thing", in: run(started(), .turnStarted(convoID: "c1")).0), .transcript("And another thing."))
        XCTAssertEqual(utterance(state), "bev is busy. It will get this when it finishes.")
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .waiting)
        XCTAssertTrue(state.isAgentWorking)
    }

    func testOfflineKeepsTheRecordingAndSaysSo() {
        let (state, effects) = run(said("merge it", in: started()), .uploadFailed)
        XCTAssertEqual(Array(effects.prefix(3)), [.cancelTimer(.transcript), .earcon(.error), .sendVoiceNote(.conversation("c1"))])
        XCTAssertEqual(utterance(state), "No connection. I'll send it when you're back online.")
    }

    func testAFailedSendIsSaidWhenTheEngineIsFree() {
        let (state, effects) = run(waiting(), .sendFailed)
        XCTAssertEqual(effects.first, .earcon(.error))
        XCTAssertEqual(utterance(state), "No connection. That wasn't sent.")
        // Busy: said after the clip in progress.
        var busy = run(waiting(), .arrived(Self.plainReply)).0
        busy = run(busy, .sendFailed).0
        XCTAssertEqual(utterance(busy), "Done.")
        busy = run(busy, .playbackFinished(busy.playing!.id)).0
        XCTAssertEqual(utterance(busy), "No connection. That wasn't sent.")
    }

    func testAMicrophoneFailureIsSaid() {
        let (state, effects) = run(started(), .captureFailed)
        XCTAssertEqual(effects.first, .earcon(.error))
        XCTAssertEqual(utterance(state), "I can't use the microphone.")
        XCTAssertNil(state.capture)
    }

    /// The microphone failing in the cancel window: he can no longer say
    /// "cancel", so the three-second timer must not send.
    func testAMicrophoneFailureDuringSendingDropsAnItemAction() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(state), "Sending: Go.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(state.phase, .confirming)
        let (failed, effects) = run(state, .captureFailed)
        XCTAssertEqual(Array(effects.prefix(4)),
                       [.earcon(.error), .cancelTimer(.confirm), .cancelTimer(.confirmGuard), .discardRecording])
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertFalse(effects.contains(.startCapture(.monitor)), "said with the microphone closed")
        XCTAssertEqual(utterance(failed), "I couldn't hear you, so I haven't sent that.")
        XCTAssertNil(failed.confirm)
        XCTAssertNil(failed.capture)
        XCTAssertNil(failed.timers[.confirm])
        // The timer the runner may already have fired changes nothing.
        let (late, lateEffects) = run(failed, .timerFired(.confirm))
        XCTAssertEqual(lateEffects, [])
        XCTAssertEqual(late, failed)
        // Then it waits.
        let (waiting, last) = run(failed, .playbackFinished(failed.playing!.id))
        XCTAssertEqual(waiting.phase, .waiting)
        XCTAssertFalse(last.contains(where: isSend))
    }

    func testAMicrophoneFailureDuringSendingDropsAPromptReply() {
        // While "Sending: SQLite." is still being said.
        let speaking = run(said("the second one", in: heard(Self.ask)), .transcript("The second one.")).0
        XCTAssertEqual(utterance(speaking), "Sending: SQLite.")
        // And in the window after it.
        let confirming = run(speaking, .playbackFinished(speaking.playing!.id), .timerFired(.confirmGuard)).0
        for state in [speaking, confirming] {
            let (failed, effects) = run(state, .captureFailed)
            XCTAssertEqual(effects.first, .earcon(.error))
            XCTAssertTrue(effects.contains(.discardRecording))
            XCTAssertFalse(effects.contains(where: isSend))
            XCTAssertEqual(utterance(failed), "I couldn't hear you, so I haven't sent that.")
            XCTAssertNil(failed.confirm)
            let (after, later) = run(failed, .playbackFinished(failed.playing!.id), .timerFired(.confirm))
            XCTAssertEqual(after.phase, .waiting)
            XCTAssertFalse(later.contains(where: isSend))
        }
    }

    /// "Did you mean …?" is dropped the same way: his "yes" could not be
    /// heard either, and saying so beats eight seconds of silence.
    func testAMicrophoneFailureDuringDidYouMeanDropsItToo() {
        var state = run(said("allow", in: heard(Self.permission)), .transcript("Allow.")).0
        XCTAssertEqual(utterance(state), "Did you mean Allow once?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (failed, effects) = run(state, .captureFailed)
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(failed), "I couldn't hear you, so I haven't sent that.")
        XCTAssertNil(failed.confirm)
    }

    /// Outside a confirmation the failure is said as before.
    func testAMicrophoneFailureUnderAReplyDoesNotStopTheReply() {
        let speaking = run(waiting(), .arrived(Self.plainReply)).0
        let (state, effects) = run(speaking, .captureFailed)
        XCTAssertEqual(effects, [.earcon(.error)])
        XCTAssertEqual(utterance(state), "Done.")
    }

    // MARK: Commands

    func testACommandIsHandledOnTheDeviceAndNothingIsUploaded() {
        let (state, effects) = run(heard(Self.reply), .speechStarted, .words("Tell me more."), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 0.6)], "a command needs less silence than a sentence")
        let (after, fx) = run(state, .timerFired(.silence))
        XCTAssertFalse(fx.contains(.upload))
        XCTAssertTrue(fx.contains(.stopCapture(keep: false)))
        XCTAssertEqual(utterance(after), "Every test passed and the cache was rebuilt.")
        XCTAssertEqual(after.playing?.level, .more)
    }

    /// The on-device words may miss a command the journal's transcript has.
    func testACommandFoundOnlyInTheTranscriptIsStillACommand() {
        let (state, effects) = run(said("mower", in: heard(Self.reply)), .transcript("More."))
        XCTAssertEqual(Array(effects.prefix(2)), [.cancelTimer(.transcript), .discardRecording])
        XCTAssertEqual(state.level, 2)
    }

    func testTheThreeLevelsOfMore() {
        var state = heard(Self.reply)
        XCTAssertEqual(state.level, 1)
        func more(_ words: String = "more") {
            state = run(state, .words(words), .timerFired(.silence)).0
        }
        func finishClip() { state = run(state, .playbackFinished(state.playing!.id)).0 }
        more()
        XCTAssertEqual(utterance(state), "Every test passed and the cache was rebuilt.")
        finishClip(); more("go on")
        XCTAssertEqual(utterance(state), "Section one. Go on?")
        XCTAssertEqual(state.playing?.level, .section)
        // "Yes" answers "Go on?".
        finishClip(); more("yes")
        XCTAssertEqual(utterance(state), "Section two. Go on?")
        finishClip(); more()
        XCTAssertEqual(utterance(state), "Section three.", "the last section asks nothing")
        finishClip(); more()
        XCTAssertEqual(utterance(state), "That's the whole message.")
    }

    func testNoToGoOnStops() {
        var state = heard(Self.reply)
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertTrue(state.askedGoOn)
        XCTAssertEqual(run(state, .words("no"), .timerFired(.silence)).0.phase, .waiting)
    }

    /// No `spoken_more` (the cleaner's fallback, or the bridge wrote NONE):
    /// "more" goes straight to the message.
    func testMoreWithoutALongerVersionReadsTheMessage() {
        let entry = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: 12, short: "Short.", sections: ["Whole message."]),
                                     convoTitle: "T")
        let state = run(heard(entry), .words("more"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Whole message.")
        XCTAssertEqual(state.level, 3)
    }

    func testRepeatReplaysTheLevelJustHeard() {
        var state = heard(Self.reply)
        state = run(state, .words("repeat that"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "The deploy finished. Shall I merge?", "no second hint on a repeat")
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("more"), .timerFired(.silence)).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(state, .words("say that again"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Every test passed and the cache was rebuilt.")
        let nothing = run(started(), .words("repeat"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(nothing), "There's nothing to repeat.")
    }

    func testStopGoesQuietAndATapOpensTheMicrophoneAgain() {
        let (state, effects) = run(heard(Self.reply), .words("stop"), .timerFired(.silence))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(effects.last, .releaseAudio)
        XCTAssertEqual(state.current, Self.reply, "still the thing an answer would be about")
        let (again, fx) = run(state, .tap)
        XCTAssertEqual(again.phase, .listening)
        XCTAssertEqual(fx, [.startTimer(.idle, 1_800), .activateAudio, .earcon(.micOpen), .startCapture(.record),
                            .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120)])
    }

    /// "Yes" is a command only to a question the engine asked itself.
    func testYesWithNothingAskedIsAMessage() {
        let state = run(heard(Self.plainReply), .words("yes"), .timerFired(.silence)).0
        XCTAssertEqual(state.phase, .sending)
    }

    /// An item may offer "Skip": the label wins over the command.
    func testALabelWinsOverACommandWord() {
        let entry = VoiceEntry.item(VoiceItem(id: "it_9", kind: .question, convoID: "c1", title: "Run the slow tests?",
                                              labels: ["Skip", "Run"]), convoTitle: "T")
        let state = run(heard(entry), .words("skip"), .timerFired(.silence)).0
        XCTAssertEqual(state.phase, .sending)
        let confirming = run(state, .transcript("Skip.")).0
        XCTAssertEqual(utterance(confirming), "Sending: Skip.")
    }

    // MARK: Speaking

    func testAReplyIsSpokenWithTheMicrophoneOpenUnderneath() {
        let (state, effects) = run(waiting(), .arrived(Self.reply))
        XCTAssertEqual(state.phase, .speaking)
        let expected = Engine.Utterance(id: 1, text: "The deploy finished. Shall I merge? Ask for the detail if you want it.", level: .short)
        XCTAssertEqual(effects, [.startTimer(.idle, 1_800), .activateAudio, .play(expected), .startCapture(.monitor)])
        XCTAssertEqual(state.caption, expected.text)
        let (listening, fx) = run(state, .playbackFinished(1))
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertEqual(fx, [.earcon(.micOpen), .promoteCapture, .startTimer(.noSpeech, 8), .startTimer(.maxUtterance, 120)])
    }

    func testTheMoreHintStopsAfterAFewTimes() {
        var state = waiting()
        var texts: [String] = []
        for seq in 1...4 {
            let entry = VoiceEntry.reply(SpokenReply(convoID: "c1", seq: Int64(seq), short: "Reply \(seq).", more: "More."),
                                         convoTitle: "T")
            state = run(state, .arrived(entry)).0
            texts.append(state.playing!.text)
            state = run(state, .playbackFinished(state.playing!.id), .timerFired(.noSpeech)).0
        }
        XCTAssertEqual(texts, ["Reply 1. Ask for the detail if you want it.", "Reply 2. Ask for the detail if you want it.",
                               "Reply 3. Ask for the detail if you want it.", "Reply 4."])
        var config = Engine.Config()
        config.offerMore = false
        XCTAssertEqual(run(waiting(config: config), .arrived(Self.reply)).0.playing?.text, "The deploy finished. Shall I merge?")
        XCTAssertEqual(run(waiting(), .arrived(Self.plainReply)).0.playing?.text, "Done.", "nothing more to offer")
    }

    func testTheSameThingIsNeverSaidTwice() {
        let state = heard(Self.reply)
        let (again, effects) = run(state, .arrived(Self.reply))
        XCTAssertEqual(again, state)
        XCTAssertEqual(effects, [])
    }

    func testSomethingArrivingWhileHeIsTalkingWaitsItsTurn() {
        var state = run(heard(Self.reply), .speechStarted, .arrived(Self.ask)).0
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.inbox, [Self.ask])
        state = run(state, .words("merge it"), .speechEnded, .timerFired(.silence), .transcript("Merge it.")).0
        XCTAssertEqual(utterance(state), "Which database? Options: Postgres, SQLite.", "said once his message has gone")
        XCTAssertEqual(state.inbox, [])
    }

    func testSomethingArrivingWhileTheMicrophoneIsOpenButSilentIsSaidAtOnce() {
        let (state, effects) = run(started(), .arrived(Self.plainReply))
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertTrue(effects.contains(.stopCapture(keep: false)))
    }

    func testATapInterruptsAClip() {
        let speaking = run(waiting(), .arrived(Self.reply)).0
        let (state, effects) = run(speaking, .tap)
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects, [.stopPlayback, .earcon(.micOpen), .promoteCapture, .startTimer(.idle, 1_800),
                                 .startTimer(.maxUtterance, 120), .startTimer(.noSpeech, 8)])
        XCTAssertNil(state.playing)
    }

    // MARK: Talking over the agent

    func testSpeechThenWordsStopsTheClip() {
        var (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted)
        XCTAssertEqual(effects, [.startTimer(.talkOverOnset, 0.3)])
        (state, effects) = run(state, .timerFired(.talkOverOnset))
        XCTAssertEqual(effects, [.duck, .startTimer(.talkOverWords, 1)], "300 ms of speech: the clip drops, nothing lost yet")
        XCTAssertTrue(state.ducked)
        (state, effects) = run(state, .words("actually wait"))
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .stopPlayback, .restoreVolume, .promoteCapture,
                                 .startTimer(.idle, 1_800), .startTimer(.maxUtterance, 120)])
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(state.heard, "actually wait")
        // He is still talking: silence ends it as usual.
        (state, effects) = run(state, .words("actually wait for the tests"), .speechEnded)
        XCTAssertEqual(effects, [.startTimer(.silence, 1.5)])
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .sending)
    }

    func testSpeechWithoutWordsResumesTheClip() {
        var state = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (resumed, effects) = run(state, .speechEnded, .timerFired(.talkOverWords))
        XCTAssertEqual(effects, [.restoreVolume], "a cough: the volume comes back and the clip carries on")
        XCTAssertEqual(resumed.phase, .speaking)
        XCTAssertFalse(resumed.ducked)
        XCTAssertEqual(resumed.falseTriggers, 1)
        // The clip then finishes as normal.
        state = run(resumed, .playbackFinished(resumed.playing!.id)).0
        XCTAssertEqual(state.phase, .listening)
    }

    func testABlipShorterThanTheOnsetDoesNothing() {
        let (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .speechEnded)
        XCTAssertEqual(effects, [.cancelTimer(.talkOverOnset)])
        XCTAssertFalse(state.ducked)
        XCTAssertEqual(run(state, .timerFired(.talkOverOnset)).1, [], "a timer already cancelled does nothing")
    }

    /// One word can be over before the recogniser reports it: the words
    /// then start the end-of-speech count themselves.
    func testAOneWordInterruptionAfterSpeechHasEnded() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset), .speechEnded).0
        let (state, effects) = run(ducked, .words("stop"))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(effects.last, .startTimer(.silence, 0.6))
        XCTAssertEqual(run(state, .timerFired(.silence)).0.phase, .waiting, "a command, acted on with no upload")
    }

    /// Words that arrive before the duck are kept and judged at the duck.
    func testWordsThatArriveBeforeTheDuckInterruptAtTheDuck() {
        let (state, effects) = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .words("hang on"), .timerFired(.talkOverOnset))
        XCTAssertEqual(state.phase, .listening)
        XCTAssertEqual(Array(effects.prefix(2)), [.duck, .startTimer(.talkOverWords, 1)])
        XCTAssertTrue(effects.contains(.stopPlayback))
    }

    /// The clip's own words coming back through the microphone are not him.
    func testTheClipsOwnWordsDoNotInterruptIt() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .words("the deploy finished"))
        XCTAssertEqual(state.phase, .speaking)
        XCTAssertEqual(effects, [])
        XCTAssertTrue(Engine.isEcho("Shall I merge", of: "The deploy finished. Shall I merge?"))
        XCTAssertFalse(Engine.isEcho("merge it now", of: "The deploy finished. Shall I merge?"))
        XCTAssertFalse(Engine.isEcho("", of: "anything"))
    }

    func testRepeatedSelfTriggersSwitchTalkingOverOffForTheRoute() {
        var state = run(waiting(), .arrived(Self.reply)).0
        var effects: [Effect] = []
        for _ in 1...3 {
            (state, effects) = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("the deploy finished"),
                                   .speechEnded, .timerFired(.talkOverWords))
        }
        XCTAssertEqual(effects, [.restoreVolume, .stopCapture(keep: false)])
        XCTAssertEqual(state.talkOverOffRoutes, ["Speaker"])
        XCTAssertFalse(state.talkOverAllowed)
        // It says so after the clip, then listens as usual.
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(utterance(state), VoicePhrases.talkOverOff)
        let (listening, fx) = run(state, .playbackFinished(state.playing!.id))
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertTrue(fx.contains(.startCapture(.record)))
        // Later clips on this route play with the microphone closed; a tap still interrupts.
        let next = run(run(listening, .timerFired(.noSpeech)).0, .arrived(Self.plainReply))
        XCTAssertFalse(next.1.contains(.startCapture(.monitor)))
        XCTAssertEqual(run(next.0, .speechStarted).1, [])
        XCTAssertEqual(run(next.0, .tap).0.phase, .listening)
        // Another route starts with it on again.
        XCTAssertTrue(run(next.0, .routeChanged("AirPods Pro")).0.talkOverAllowed)
    }

    func testTheCountOfFalseStartsBeginsAgainWithEachClip() {
        var state = run(waiting(), .arrived(Self.reply)).0
        for _ in 1...2 { state = run(state, .speechStarted, .timerFired(.talkOverOnset), .timerFired(.talkOverWords)).0 }
        XCTAssertEqual(state.falseTriggers, 2)
        state = run(state, .playbackFinished(state.playing!.id), .timerFired(.noSpeech), .arrived(Self.plainReply)).0
        XCTAssertEqual(state.falseTriggers, 0)
    }

    func testWithTalkingOverSwitchedOffOnlyATapInterrupts() {
        var config = Engine.Config()
        config.talkOver = false
        let (state, effects) = run(waiting(config: config), .arrived(Self.reply))
        XCTAssertFalse(effects.contains(.startCapture(.monitor)))
        XCTAssertEqual(run(state, .speechStarted, .words("hello")).0.phase, .speaking)
        let (tapped, fx) = run(state, .tap)
        XCTAssertEqual(tapped.phase, .listening)
        XCTAssertTrue(fx.contains(.startCapture(.record)))
    }

    func testSwitchingTalkingOverOffMidClipClosesTheMicrophone() {
        var config = Engine.Config()
        config.talkOver = false
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .configChanged(config))
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .restoreVolume, .stopCapture(keep: false)])
        XCTAssertNil(state.capture)
    }

    // MARK: Answering items and prompts (§4)

    func testAClearMatchIsReadBackThenSentAfterThreeSeconds() {
        var (state, effects) = run(said("yes go", in: heard(Self.item)), .transcript("Yes, go."))
        XCTAssertEqual(utterance(state), "Sending: Go.")
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        (state, effects) = run(state, .playbackFinished(state.playing!.id))
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertEqual(effects, [.startTimer(.confirm, 3), .startTimer(.confirmGuard, 0.3)])
        (state, effects) = run(state, .timerFired(.confirmGuard), .timerFired(.confirm))
        XCTAssertEqual(effects, [.sendItemAction(itemID: "it_1", label: "Go"), .discardRecording, .earcon(.sent),
                                 .startTimer(.idle, 1_800), .stopCapture(keep: false), .releaseAudio])
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.current)
    }

    func testCancelInsideTheWindowStopsTheSend() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .playbackFinished(state.playing!.id), .timerFired(.confirmGuard), .speechStarted).0
        let (cancelled, effects) = run(state, .words("cancel"))
        XCTAssertEqual(Array(effects.prefix(2)), [.cancelTimer(.confirm), .discardRecording])
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(cancelled), "Cancelled.")
        XCTAssertNil(cancelled.confirm)
        // Then it listens again, for the same item.
        let listening = run(cancelled, .playbackFinished(cancelled.playing!.id)).0
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertEqual(listening.current, Self.item)
    }

    func testCancelSpokenOverTheReadBackStopsTheSendToo() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("cancel"), .speechEnded).0
        XCTAssertEqual(state.phase, .listening)
        XCTAssertNotNil(state.confirm, "still pending until the utterance is understood")
        let (after, effects) = run(state, .timerFired(.silence))
        XCTAssertFalse(effects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(after), "Cancelled.")
    }

    /// Anything else said over a confirmation: not sent, and what he said
    /// is taken as a new utterance.
    func testTalkingOverAConfirmationWithSomethingElseDropsIt() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .speechStarted, .timerFired(.talkOverOnset), .words("no I meant wait"), .speechEnded).0
        let (after, effects) = run(state, .timerFired(.silence))
        XCTAssertEqual(after.phase, .sending)
        XCTAssertNil(after.confirm)
        XCTAssertEqual(Array(effects.suffix(4)), [.discardRecording, .stopCapture(keep: true), .upload, .startTimer(.transcript, 8)])
    }

    func testATapCancelsAConfirmation() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(run(state, .tap).0), "Cancelled.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(utterance(run(state, .tap).0), "Cancelled.")
    }

    func testAnUnsureMatchAsksAndSendsOnlyOnYes() {
        var state = run(said("go after lunch", in: heard(Self.item)), .transcript("Go, after lunch.")).0
        XCTAssertEqual(utterance(state), "Did you mean Go?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertNotNil(state.timers[.confirm])
        // He answers: speech that starts after the question and its guard.
        state = run(state, .timerFired(.confirmGuard), .speechStarted).0
        let (yes, yesEffects) = run(state, .words("yes"))
        XCTAssertEqual(yesEffects.first, .cancelTimer(.confirm))
        XCTAssertTrue(yesEffects.contains(.sendItemAction(itemID: "it_1", label: "Go")))
        XCTAssertEqual(yes.phase, .waiting)
        let (no, noEffects) = run(state, .words("no"))
        XCTAssertFalse(noEffects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(no), "OK, not sent.")
        // Words that are neither are ignored; silence means no.
        let (ignored, _) = run(state, .words("hmm let me think"))
        XCTAssertEqual(ignored.phase, .confirming)
        let (timedOut, timeoutEffects) = run(state, .timerFired(.confirm))
        XCTAssertFalse(timeoutEffects.contains { if case .sendItemAction = $0 { return true } else { return false } })
        XCTAssertEqual(utterance(timedOut), "OK, not sent.")
        XCTAssertEqual(run(timedOut, .playbackFinished(timedOut.playing!.id)).0.phase, .waiting)
    }

    /// The hint that teaches "more" is part of the clip, and words that
    /// are the clip's own do not interrupt it: the hint must not contain
    /// the command.
    func testMoreSaidOverTheHintInterruptsTheReply() {
        let speaking = run(waiting(), .arrived(Self.reply)).0
        XCTAssertEqual(utterance(speaking), "The deploy finished. Shall I merge? Ask for the detail if you want it.")
        let (state, effects) = run(speaking, .speechStarted, .timerFired(.talkOverOnset), .words("more"))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertEqual(state.phase, .listening)
        // And it is then run as the command.
        let after = run(state, .speechEnded, .timerFired(.silence)).0
        XCTAssertEqual(utterance(after), "Every test passed and the cache was rebuilt.")
    }

    // MARK: A confirmation cannot be answered by the engine's own clip

    /// A prompt whose labels are themselves the words that answer a
    /// confirmation: "Did you mean Yes?" ends in a yes.
    static let yesNo = VoiceEntry.prompt(
        VoicePrompt(convoID: "c3", seq: 31, question: "Ship it?",
                    options: [.init(label: "Yes", value: "y"), .init(label: "No", value: "n")]),
        convoTitle: "Schema", boxName: "bev")

    /// "Did you mean Yes?" has been said and the engine is `confirming`.
    func askedDidYouMeanYes() -> Engine.State {
        let state = run(said("yes after lunch", in: heard(Self.yesNo)), .transcript("Yes, after lunch.")).0
        XCTAssertEqual(utterance(state), "Did you mean Yes?")
        return run(state, .playbackFinished(state.playing!.id)).0
    }

    func isSend(_ effect: Effect) -> Bool {
        switch effect {
        case .sendItemAction, .sendPromptReply, .sendVoiceNote: return true
        default: return false
        }
    }

    /// The recogniser can deliver the clip's last word after the clip has
    /// finished. With no speech starting after the question, that word is
    /// the question's own and answers nothing.
    func testLateWordsFromTheQuestionClipDoNotConfirm() {
        let state = askedDidYouMeanYes()
        XCTAssertEqual(state.phase, .confirming)
        let (after, effects) = run(state, .words("yes"))
        XCTAssertEqual(effects, [])
        XCTAssertEqual(after.phase, .confirming)
        XCTAssertNotNil(after.confirm)
    }

    /// Entering `confirming` starts the guard: speech that starts inside
    /// it is still taken for the clip, and its words answer nothing.
    func testSpeechInsideTheGuardDoesNotCount() {
        var state = run(said("yes after lunch", in: heard(Self.yesNo)), .transcript("Yes, after lunch.")).0
        let (confirming, effects) = run(state, .playbackFinished(state.playing!.id))
        XCTAssertEqual(effects, [.startTimer(.confirm, 8), .startTimer(.confirmGuard, 0.3)])
        XCTAssertFalse(confirming.confirmOnset)
        // An onset reported inside the guard, with the word after it.
        var fx: [Effect]
        (state, fx) = run(confirming, .speechStarted, .words("yes"))
        XCTAssertEqual(fx, [])
        XCTAssertEqual(state.phase, .confirming)
        // The guard passing does not turn that speech into an onset.
        (state, fx) = run(state, .timerFired(.confirmGuard), .words("yes"))
        XCTAssertEqual(fx, [])
        XCTAssertNotNil(state.confirm)
        // It ends, and he then speaks: that is one.
        (state, fx) = run(state, .speechEnded, .speechStarted, .words("yes"))
        XCTAssertTrue(fx.contains(.sendPromptReply(convoID: "c3", seq: 31, choice: "y", text: nil)))
    }

    /// A real "yes" commits, even when the label is "Yes" (a rule that
    /// compared his words with the clip's would take it for an echo).
    func testARealYesAfterAFreshOnsetCommitsEvenWhenTheLabelIsYes() {
        let state = run(askedDidYouMeanYes(), .timerFired(.confirmGuard)).0
        let (after, effects) = run(state, .speechStarted, .words("Yes."))
        XCTAssertEqual(effects.first, .cancelTimer(.confirm))
        XCTAssertTrue(effects.contains(.sendPromptReply(convoID: "c3", seq: 31, choice: "y", text: nil)))
        XCTAssertNil(after.confirm)
        XCTAssertFalse(after.confirmOnset)
    }

    func testNoAfterAFreshOnsetDoesNotSend() {
        let state = run(askedDidYouMeanYes(), .timerFired(.confirmGuard)).0
        let (after, effects) = run(state, .speechStarted, .words("no"))
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(after), "OK, not sent.")
    }

    func testCancelAfterAFreshOnsetCancels() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(state), "Sending: Go.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (cancelled, effects) = run(state, .timerFired(.confirmGuard), .speechStarted, .words("cancel"))
        XCTAssertEqual(Array(effects.prefix(2)), [.cancelTimer(.confirm), .discardRecording])
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(cancelled), "Cancelled.")
        XCTAssertNil(cancelled.confirm)
    }

    // Declining needs no proof that the words are his. An echo of the
    // question can at worst cancel; a "cancel" that is ignored sends.

    /// "Cancel" the moment the clip ends: no guard fired, no onset seen.
    func testCancelToSendingNeedsNoOnset() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(state), "Sending: Go.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(state.phase, .confirming)
        XCTAssertNotNil(state.timers[.confirmGuard])
        XCTAssertFalse(state.confirmOnset)
        let (cancelled, effects) = run(state, .words("cancel"))
        XCTAssertEqual(Array(effects.prefix(3)), [.cancelTimer(.confirm), .cancelTimer(.confirmGuard), .discardRecording])
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(cancelled), "Cancelled.")
        XCTAssertNil(cancelled.confirm)
        // The window's timer, fired late by a runner, sends nothing.
        XCTAssertEqual(run(cancelled, .timerFired(.confirm)).1, [])
        // The same with speech that started inside the guard, and with "no" and "stop".
        XCTAssertEqual(utterance(run(state, .speechStarted, .words("Cancel that.")).0), "Cancelled.")
        XCTAssertEqual(utterance(run(state, .words("no")).0), "Cancelled.")
        XCTAssertEqual(utterance(run(state, .words("stop")).0), "Cancelled.")
    }

    func testNoToDidYouMeanNeedsNoOnset() {
        var state = run(said("go after lunch", in: heard(Self.item)), .transcript("Go, after lunch.")).0
        XCTAssertEqual(utterance(state), "Did you mean Go?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (declined, effects) = run(state, .words("no"))
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(declined), "OK, not sent.")
        XCTAssertNil(declined.confirm)
        XCTAssertEqual(utterance(run(state, .words("cancel")).0), "OK, not sent.")
        // "Yes" from the same place still needs him to have started speaking.
        XCTAssertEqual(run(state, .words("yes")).1, [])
    }

    /// He says "cancel" in the last moment of "Sending: Go.": too late for
    /// the clip to duck, and the recogniser has nothing more to deliver
    /// once the clip has ended. What was heard under the clip still counts.
    func testCancelHeardUnderTheClipBeforeItDucksStillCancels() {
        let speaking = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        XCTAssertEqual(utterance(speaking), "Sending: Go.")
        let under = run(speaking, .speechStarted, .words("cancel")).0
        XCTAssertEqual(under.phase, .speaking, "not ducked yet: the clip carries on")
        XCTAssertNotNil(under.confirm)
        let (after, effects) = run(under, .playbackFinished(under.playing!.id))
        XCTAssertFalse(effects.contains(where: isSend))
        XCTAssertEqual(utterance(after), "Cancelled.")
        XCTAssertNil(after.confirm)
        XCTAssertNil(after.timers[.confirm])
        // A "yes" heard under the clip confirms nothing.
        let yes = run(speaking, .speechStarted, .words("yes")).0
        let (still, none) = run(yes, .playbackFinished(yes.playing!.id))
        XCTAssertEqual(still.phase, .confirming)
        XCTAssertFalse(none.contains(where: isSend))
    }

    /// Talking over the clip for long enough to duck it: as before.
    func testCancelSpokenAsTalkOverWhileTheClipPlaysCancels() {
        let speaking = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        let (state, effects) = run(speaking, .speechStarted, .timerFired(.talkOverOnset), .words("cancel"))
        XCTAssertTrue(effects.contains(.stopPlayback))
        let (after, fx) = run(state, .speechEnded, .timerFired(.silence))
        XCTAssertFalse(fx.contains(where: isSend))
        XCTAssertEqual(utterance(after), "Cancelled.")
        XCTAssertNil(after.confirm)
    }

    /// A tap is not a sound: it works before the clip ends, inside the
    /// guard and after it.
    func testATapWorksAtAnyTimeInAConfirmation() {
        let speaking = run(said("yes after lunch", in: heard(Self.yesNo)), .transcript("Yes, after lunch.")).0
        let insideGuard = run(speaking, .playbackFinished(speaking.playing!.id)).0
        let afterGuard = run(insideGuard, .timerFired(.confirmGuard)).0
        for state in [speaking, insideGuard, afterGuard] {
            let (after, effects) = run(state, .tap)
            XCTAssertFalse(effects.contains(where: isSend))
            XCTAssertEqual(utterance(after), "OK, not sent.")
            XCTAssertNil(after.confirm)
            XCTAssertNil(after.timers[.confirm])
            XCTAssertNil(after.timers[.confirmGuard])
        }
        // A label button sends at once, inside the guard too.
        let (_, tapped) = run(insideGuard, .actionTapped("Yes"))
        XCTAssertTrue(tapped.contains(.sendPromptReply(convoID: "c3", seq: 31, choice: "y", text: nil)))
        XCTAssertTrue(tapped.contains(.cancelTimer(.confirmGuard)))
    }

    /// The window's own timer does not need an onset: "Sending: Go" still
    /// goes after three seconds of nothing, and "Did you mean" still does not.
    func testTheWindowTimersNeedNoOnset() {
        var state = run(said("go", in: heard(Self.item)), .transcript("Go.")).0
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (_, effects) = run(state, .timerFired(.confirm))
        XCTAssertEqual(effects.first, .cancelTimer(.confirmGuard), "committed inside the guard: the guard goes too")
        XCTAssertTrue(effects.contains(.sendItemAction(itemID: "it_1", label: "Go")))
        let (timedOut, none) = run(askedDidYouMeanYes(), .timerFired(.confirmGuard), .timerFired(.confirm))
        XCTAssertFalse(none.contains(where: isSend))
        XCTAssertEqual(utterance(timedOut), "OK, not sent.")
    }

    func testNoMatchOnAnItemIsAVoiceNoteComment() {
        let (state, effects) = run(said("why not next week", in: heard(Self.item)), .transcript("Why not next week?"))
        XCTAssertEqual(Array(effects.prefix(3)), [.cancelTimer(.transcript), .sendVoiceNote(.item("it_1")), .earcon(.sent)])
        XCTAssertEqual(state.phase, .waiting)
    }

    func testAPromptOptionIsSentAsItsValue() {
        var state = run(said("the second one", in: heard(Self.ask)), .transcript("The second one.")).0
        XCTAssertEqual(utterance(state), "Sending: SQLite.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertTrue(run(state, .timerFired(.confirm)).1.contains(
            .sendPromptReply(convoID: "c3", seq: 30, choice: "lite", text: nil)))
    }

    func testNoMatchOnAPromptIsFreeText() {
        let (_, effects) = run(said("use mysql", in: heard(Self.ask)), .transcript("Use MySQL instead."))
        XCTAssertEqual(Array(effects.prefix(4)), [
            .cancelTimer(.transcript), .discardRecording,
            .sendPromptReply(convoID: "c3", seq: 30, choice: nil, text: "Use MySQL instead."), .earcon(.sent),
        ])
    }

    /// Tool permissions always ask, whatever was heard.
    func testAllowingAPermissionAlwaysAsksFirst() {
        var state = run(said("allow", in: heard(Self.permission)), .transcript("Allow.")).0
        XCTAssertEqual(utterance(state), "Did you mean Allow once?")
        state = run(state, .playbackFinished(state.playing!.id)).0
        XCTAssertEqual(run(state, .words("yes")).1, [], "not on a word with no speech of his before it")
        let (_, effects) = run(state, .timerFired(.confirmGuard), .speechStarted, .words("yes"))
        XCTAssertTrue(effects.contains(.sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):allow", text: nil)))
        let always = run(said("always allow", in: heard(Self.permission)), .transcript("Always allow.")).0
        XCTAssertEqual(utterance(always), "Did you mean Always allow Bash (session)?")
    }

    func testDenyingAPermissionNeedsNoConfirmation() {
        let (state, effects) = run(said("deny", in: heard(Self.permission)), .transcript("Deny."))
        XCTAssertEqual(Array(effects.prefix(4)), [
            .cancelTimer(.transcript), .discardRecording,
            .sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):deny", text: nil), .earcon(.sent),
        ])
        XCTAssertEqual(utterance(state), "Denied.")
    }

    func testAnythingElseSaidToAPermissionAsksAgain() {
        let (state, effects) = run(said("what does it do", in: heard(Self.permission)), .transcript("What does it do?"))
        XCTAssertEqual(utterance(state), "Say allow or deny.")
        XCTAssertFalse(effects.contains { if case .sendPromptReply = $0 { return true } else { return false } })
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .listening)
    }

    func testAPermissionThatTimesOutIsSaid() {
        let (state, _) = run(heard(Self.permission), .resolved(id: "prompt:40", expired: true))
        XCTAssertEqual(utterance(state), "That permission request timed out and was denied.")
        XCTAssertNil(state.current)
    }

    func testSomethingAnsweredElsewhereIsDropped() {
        var state = run(heard(Self.reply), .speechStarted, .arrived(Self.ask), .arrived(Self.item)).0
        state = run(state, .resolved(id: "prompt:30", expired: false)).0
        XCTAssertEqual(state.inbox, [Self.item])
        // The thing being read out: it stops and the engine moves on.
        let speaking = run(waiting(), .arrived(Self.ask)).0
        let (after, effects) = run(speaking, .resolved(id: "prompt:30", expired: false))
        XCTAssertTrue(effects.contains(.stopPlayback))
        XCTAssertEqual(after.phase, .waiting)
    }

    func testAButtonTapSendsAtOnce() {
        let (state, effects) = run(heard(Self.item), .actionTapped("Wait"))
        XCTAssertEqual(Array(effects.prefix(2)), [.sendItemAction(itemID: "it_1", label: "Wait"), .earcon(.sent)])
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertEqual(run(heard(Self.item), .actionTapped("Nope")).1, [], "not one of its labels")
        let (_, prompt) = run(heard(Self.permission), .actionTapped("Allow once"))
        XCTAssertEqual(prompt.first, .sendPromptReply(convoID: "c1", seq: 40, choice: "perm:\(Self.permissionID):allow", text: nil))
        // Mid-send: the recording is dropped and its transcript ignored.
        let sending = said("erm", in: heard(Self.item))
        let (tapped, fx) = run(sending, .actionTapped("Go"))
        XCTAssertEqual(Array(fx.prefix(3)), [.cancelTimer(.transcript), .discardRecording, .sendItemAction(itemID: "it_1", label: "Go")])
        XCTAssertEqual(run(tapped, .transcript("Erm.")).1, [])
    }

    func testAThingThatNeedsTheScreenIsRefusedAndPassedOver() {
        let (state, _) = run(waiting(), .arrived(Self.secret))
        XCTAssertEqual(utterance(state), "That one needs the screen. It's in your tracker.")
        XCTAssertEqual(state.labels, [])
        XCTAssertEqual(run(state, .playbackFinished(state.playing!.id)).0.phase, .waiting)
    }

    // MARK: The queue (§5)

    func queueStart(_ entries: [VoiceEntry], last: String? = "c9") -> (Engine.State, [Effect]) {
        run(Engine.State(), .start(.queue(entries: entries, lastConvoID: last, lastTitle: "Last chat", lastBoxName: "bev")))
    }

    func testTheQueueSaysTheCountReadsTheFirstAndListens() {
        let (state, effects) = queueStart([Self.permission, Self.item, Self.reply])
        XCTAssertEqual(utterance(state),
                       "Three things need you. In Auth refactor. bev wants to run a command: git push origin main. Allow or deny?")
        XCTAssertEqual(Array(effects.prefix(4)), [.keepScreenAwake(true), .startTimer(.idle, 1_800), .watch(convoID: "c9"),
                                                 .watch(convoID: "c1")])
        XCTAssertEqual(state.queue, [Self.item, Self.reply])
        XCTAssertEqual(state.labels, ["Allow once", "Always allow Bash (session)", "Deny"])
        XCTAssertEqual(run(state, .playbackFinished(1)).0.phase, .listening)
    }

    func testSkipMovesOnAndAnAnswerMovesOnAfterItIsSent() {
        var state = queueStart([Self.item, Self.ask, Self.reply]).0
        state = run(state, .playbackFinished(state.playing!.id), .words("skip"), .timerFired(.silence)).0
        XCTAssertEqual(utterance(state), "Schema. Which database? Options: Postgres, SQLite.")
        state = run(state, .playbackFinished(state.playing!.id)).0
        state = run(said("postgres", in: state), .transcript("Postgres.")).0
        state = run(state, .playbackFinished(state.playing!.id), .timerFired(.confirm)).0
        XCTAssertEqual(utterance(state), "Auth refactor. The deploy finished. Shall I merge? Ask for the detail if you want it.")
        // A plain answer to a reply goes to that reply's conversation.
        state = run(state, .playbackFinished(state.playing!.id)).0
        let (done, effects) = run(said("yes merge it", in: state), .transcript("Yes, merge it."))
        XCTAssertTrue(effects.contains(.sendVoiceNote(.conversation("c1"))))
        XCTAssertEqual(utterance(done), "That's everything.")
        // Then it listens on the conversation used last.
        let listening = run(done, .playbackFinished(done.playing!.id)).0
        XCTAssertEqual(listening.phase, .listening)
        XCTAssertFalse(listening.inQueue)
        let (_, last) = run(said("anything new", in: listening), .transcript("Anything new?"))
        XCTAssertTrue(last.contains(.sendVoiceNote(.conversation("c9"))))
    }

    func testAnEmptyQueueSaysSoAndListensOnTheLastConversation() {
        let (state, _) = queueStart([])
        XCTAssertEqual(utterance(state), "Nothing needs you.")
        XCTAssertEqual(run(state, .playbackFinished(1)).0.phase, .listening)
        let (none, _) = queueStart([], last: nil)
        XCTAssertEqual(run(none, .playbackFinished(1)).0.phase, .waiting, "nowhere to listen")
        let (nowhere, effects) = run(run(none, .playbackFinished(1), .tap).0, .words("hello there"), .timerFired(.silence),
                                     .transcript("Hello there."))
        XCTAssertTrue(effects.contains(.discardRecording))
        XCTAssertEqual(utterance(nowhere), "There's no conversation to send that to.")
    }

    func testSomethingNewJumpsTheQueue() {
        var state = queueStart([Self.item, Self.reply]).0
        state = run(state, .arrived(Self.permission)).0
        state = run(state, .playbackFinished(state.playing!.id), .actionTapped("Go")).0
        XCTAssertTrue(utterance(state)!.hasPrefix("In Auth refactor. bev wants to run a command"))
    }

    // MARK: Pausing, idling, ending (§6, §11, §12)

    func testACallPausesAndWhatWasCutOffIsSaidAgainAfterwards() {
        let speaking = run(waiting(), .arrived(Self.reply)).0
        let (paused, effects) = run(speaking, .interruption(.began))
        XCTAssertEqual(effects, [.stopCapture(keep: false), .stopPlayback, .releaseAudio])
        XCTAssertEqual(paused.phase, .waiting)
        XCTAssertTrue(paused.paused)
        // What lands meanwhile waits.
        let more = run(paused, .arrived(Self.ask)).0
        XCTAssertEqual(more.phase, .waiting)
        let (resumed, _) = run(more, .interruption(.ended(shouldResume: true)))
        XCTAssertEqual(utterance(resumed), "The deploy finished. Shall I merge? Ask for the detail if you want it.")
        XCTAssertEqual(resumed.inbox, [Self.ask])
    }

    func testLeavingTheAppPausesAndComingBackSaysWhatLanded() {
        let (paused, effects) = run(started(), .speechStarted, .appBackgrounded)
        XCTAssertEqual(effects, [.cancelTimer(.maxUtterance), .stopCapture(keep: false), .releaseAudio])
        let landed = run(paused, .arrived(Self.plainReply)).0
        XCTAssertEqual(landed.inbox, [Self.plainReply])
        XCTAssertEqual(utterance(run(landed, .appForegrounded).0), "Done.")
        XCTAssertEqual(run(paused, .appForegrounded).0.phase, .waiting, "nothing landed: stay quiet")
    }

    func testAnInterruptionThatDoesNotResumeWaitsForATap() {
        let paused = run(run(waiting(), .arrived(Self.reply)).0, .interruption(.began), .interruption(.ended(shouldResume: false))).0
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(run(paused, .tap).0.phase, .listening)
    }

    /// A call arriving mid-send: the message still goes, silently.
    func testPausedMidSendStillSends() {
        let sending = said("merge it", in: started())
        let (state, effects) = run(sending, .interruption(.began), .transcript("Merge it."))
        XCTAssertTrue(effects.contains(.sendVoiceNote(.conversation("c1"))))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertNil(state.playing)
    }

    func testThirtyMinutesWithoutAnExchangeEndsVoiceMode() {
        let (state, effects) = run(waiting(), .timerFired(.idle))
        XCTAssertEqual(effects, [.keepScreenAwake(false), .ended(.idle)])
        XCTAssertEqual(state.phase, .idle)
        // An exchange starts the thirty minutes again.
        XCTAssertTrue(run(waiting(), .tap).1.contains(.startTimer(.idle, 1_800)))
        XCTAssertTrue(run(waiting(), .arrived(Self.reply)).1.contains(.startTimer(.idle, 1_800)))
    }

    func testEndStopsEverything() {
        let ducked = run(run(waiting(), .arrived(Self.reply)).0, .speechStarted, .timerFired(.talkOverOnset)).0
        let (state, effects) = run(ducked, .end)
        XCTAssertEqual(effects, [.cancelTimer(.talkOverWords), .cancelTimer(.idle), .stopPlayback, .restoreVolume,
                                 .stopCapture(keep: false), .releaseAudio, .keepScreenAwake(false), .ended(.user)])
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.route, "Speaker", "the route and what was learned about it survive")
    }

    func testEndingMidSendStillSendsWhatHeSaid() {
        let (_, effects) = run(said("merge it", in: started()), .end)
        XCTAssertEqual(effects.first, .sendVoiceNote(.conversation("c1")))
        XCTAssertEqual(effects.last, .ended(.user))
    }

    func testTurnEventsTrackWhoIsWorking() {
        var state = run(started(), .turnStarted(convoID: "c1")).0
        XCTAssertTrue(state.isAgentWorking)
        state = run(state, .turnEnded(convoID: "c1")).0
        XCTAssertFalse(state.isAgentWorking)
    }

    // MARK: Timer tokens

    /// Every `startTimer` carries a token no earlier one had, and the
    /// state remembers the current one for each armed timer.
    func testEachTimerStartCarriesAFreshToken() {
        let (state, effects) = Engine.reduce(Engine.State(), .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev")))
        XCTAssertEqual(effects, [
            .keepScreenAwake(true), .startTimer(.idle, 1_800, token: 1), .watch(convoID: "c1"), .activateAudio,
            .earcon(.micOpen), .startCapture(.record), .startTimer(.noSpeech, 8, token: 2),
            .startTimer(.maxUtterance, 120, token: 3),
        ])
        XCTAssertEqual(state.timers, [.idle: 1, .noSpeech: 2, .maxUtterance: 3])
        // Restarting one replaces its token and cancels nothing.
        let (restarted, fx) = Engine.reduce(run(state, .timerFired(.noSpeech)).0, .tap)
        XCTAssertEqual(fx.first, .startTimer(.idle, 1_800, token: 4))
        XCTAssertFalse(fx.contains(.cancelTimer(.idle)))
        XCTAssertEqual(restarted.timers[.idle], 4)
    }

    /// The idle timer is restarted by every exchange with no cancel. A
    /// runner that lets the old one fire as well must not end voice mode.
    func testAStaleIdleFiringAfterARestartDoesNothing() throws {
        let before = waiting()
        let old = try XCTUnwrap(before.timers[.idle])
        let state = run(before, .tap).0
        let current = try XCTUnwrap(state.timers[.idle])
        XCTAssertNotEqual(old, current)

        let (same, none) = Engine.reduce(state, .timerFired(.idle, token: old))
        XCTAssertEqual(none, [])
        XCTAssertEqual(same, state)
        XCTAssertEqual(same.phase, .listening)

        let (ended, effects) = Engine.reduce(state, .timerFired(.idle, token: current))
        XCTAssertEqual(effects.last, .ended(.idle))
        XCTAssertEqual(ended.phase, .idle)
    }

    /// The first "Sending: Go" was cancelled and a second is in its
    /// window: the first window's timer, fired late, must not send the
    /// second before its three seconds are up.
    func testAStaleConfirmFiringDoesNotSend() throws {
        func inWindow(_ state: Engine.State) -> Engine.State {
            let reading = run(said("go", in: state), .transcript("Go.")).0
            XCTAssertEqual(utterance(reading), "Sending: Go.")
            return run(reading, .playbackFinished(reading.playing!.id)).0
        }
        let first = inWindow(heard(Self.item))
        let old = try XCTUnwrap(first.timers[.confirm])
        let cancelled = run(first, .tap).0
        let second = inWindow(run(cancelled, .playbackFinished(cancelled.playing!.id)).0)
        let current = try XCTUnwrap(second.timers[.confirm])
        XCTAssertNotEqual(old, current)

        let (same, none) = Engine.reduce(second, .timerFired(.confirm, token: old))
        XCTAssertEqual(none, [])
        XCTAssertEqual(same, second)
        XCTAssertNotNil(same.confirm)

        let (sent, effects) = Engine.reduce(second, .timerFired(.confirm, token: current))
        XCTAssertTrue(effects.contains(.sendItemAction(itemID: "it_1", label: "Go")))
        XCTAssertNil(sent.confirm)
    }

    /// Tokens carry on across sessions, so a timer left over from the
    /// last one cannot match a timer of this one.
    func testTokensAreNotReusedAfterVoiceModeEndsAndStartsAgain() throws {
        let first = started()
        let old = try XCTUnwrap(first.timers[.idle])
        let ended = run(first, .end).0
        XCTAssertEqual(ended.phase, .idle)
        XCTAssertEqual(ended.timers, [:])
        let second = run(ended, .start(.conversation(id: "c1", title: "Auth refactor", boxName: "bev"))).0
        let current = try XCTUnwrap(second.timers[.idle])
        XCTAssertGreaterThan(current, old)
        XCTAssertEqual(Set(second.timers.values).count, second.timers.count)
        let (same, none) = Engine.reduce(second, .timerFired(.idle, token: old))
        XCTAssertEqual(none, [])
        XCTAssertEqual(same, second)
    }

    /// A timer that was cancelled, or that has already fired, is not armed:
    /// its token is spent.
    func testACancelledOrSpentTimerDoesNotFireAgain() throws {
        let listening = started()
        let token = try XCTUnwrap(listening.timers[.noSpeech])
        // Cancelled by speech starting.
        let speaking = run(listening, .speechStarted).0
        XCTAssertNil(speaking.timers[.noSpeech])
        XCTAssertEqual(Engine.reduce(speaking, .timerFired(.noSpeech, token: token)).1, [])
        // Fired once: the second delivery of the same firing does nothing.
        let (waiting, _) = Engine.reduce(listening, .timerFired(.noSpeech, token: token))
        XCTAssertEqual(waiting.phase, .waiting)
        let (again, none) = Engine.reduce(waiting, .timerFired(.noSpeech, token: token))
        XCTAssertEqual(none, [])
        XCTAssertEqual(again, waiting)
    }
}

// MARK: - Token-less spellings

extension VoiceModeEngine.Effect {
    /// What `run` blanks every `startTimer` token to. The engine's tokens
    /// start at 1, so this is never a real one.
    static let anyToken = 0

    /// `.startTimer(.idle, 1_800)`: the effect with its token blanked, as
    /// `run` returns it.
    static func startTimer(_ id: VoiceModeEngine.TimerID, _ interval: TimeInterval) -> Self {
        .startTimer(id, interval, token: anyToken)
    }
}

extension VoiceModeEngine.Event {
    /// Stands for "the token this timer has when the event is fed in";
    /// `run` swaps the real one in.
    static let currentToken = Int.min

    /// `.timerFired(.silence)`: the timer firing as armed.
    static func timerFired(_ id: VoiceModeEngine.TimerID) -> Self {
        .timerFired(id, token: currentToken)
    }
}

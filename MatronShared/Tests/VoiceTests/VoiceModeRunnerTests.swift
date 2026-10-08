import Observation
import XCTest
@testable import MatronVoice

@MainActor
final class VoiceModeRunnerTests: XCTestCase {
    final class FakeCapture: VoiceCapturing {
        let events: AsyncStream<VoiceCaptureEvent>
        let continuation: AsyncStream<VoiceCaptureEvent>.Continuation
        var log: [String] = []
        var startError: Error?
        var fileToReturn: URL?
        /// A start that does not return until `releaseStart()`: the
        /// permission prompt left unanswered, a model still downloading.
        var holdsStart = false
        private var heldStart: CheckedContinuation<Void, Never>?
        /// A stop that does not return until `releaseStop()`.
        var holdsStop = false
        private var heldStop: CheckedContinuation<Void, Never>?
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self) }
        func start(_ mode: VoiceModeEngine.CaptureMode) async throws {
            if let startError { throw startError }
            log.append("start \(mode.rawValue)")
            if holdsStart {
                await withCheckedContinuation { heldStart = $0 }
                log.append("started \(mode.rawValue)")
            }
        }
        func releaseStart() {
            heldStart?.resume()
            heldStart = nil
        }
        func promote() { log.append("promote") }
        func stop(keep: Bool) async -> URL? {
            log.append("stop keep=\(keep)")
            if holdsStop { await withCheckedContinuation { heldStop = $0 } }
            return keep ? fileToReturn : nil
        }
        func releaseStop() {
            heldStop?.resume()
            heldStop = nil
        }
    }

    final class FakeAudio: VoiceAudioControlling {
        let events: AsyncStream<VoiceModeEngine.Event>
        let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
        var routeName = "Speaker"
        var log: [String] = []
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self) }
        func activate() throws { log.append("activate") }
        func release() { log.append("release") }
    }

    final class FakePlayer: SpeechPlaying {
        var spoken: [String] = []
        var earcons: [VoiceModeEngine.Earcon] = []
        var ducks: [Bool] = []
        var stops = 0
        /// Lines whose playback the test finishes by hand.
        var held: [CheckedContinuation<SpeechPlayer.Source, Never>] = []
        var holds = false
        /// What a line that is not held reports.
        var source = SpeechPlayer.Source.cloud
        func speak(_ text: String) async -> SpeechPlayer.Source {
            spoken.append(text)
            guard holds else { return source }
            return await withCheckedContinuation { held.append($0) }
        }
        func stop() {
            stops += 1
            held.forEach { $0.resume(returning: .stopped) }
            held = []
        }
        func setDucked(_ ducked: Bool) { ducks.append(ducked) }
        func play(_ earcon: VoiceModeEngine.Earcon) { earcons.append(earcon) }
    }

    final class FakeSender: VoiceSending, @unchecked Sendable {
        var uploads: [Data] = []
        var uploadError: Error?
        var transcriptText: String? = "Merge it."
        var voiceNotes: [(ref: String, size: Int, target: VoiceModeEngine.SendTarget)] = []
        var sendError: Error?
        var itemActions: [(String, String)] = []
        var promptReplies: [(String, Int64, String?, String?)] = []
        func upload(_ audio: Data) async throws -> String {
            if let uploadError { throw uploadError }
            uploads.append(audio)
            return "m-\(uploads.count)"
        }
        func transcript(blobRef: String, waitSeconds: Int) async -> String? { transcriptText }
        func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws {
            if let sendError { throw sendError }
            voiceNotes.append((blobRef, size, target))
        }
        func sendItemAction(itemID: String, label: String) async { itemActions.append((itemID, label)) }
        func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws {
            if let sendError { throw sendError }
            promptReplies.append((convoID, seq, choice, text))
        }
    }

    final class FakeFeed: VoiceFeeding {
        let events: AsyncStream<VoiceModeEngine.Event>
        let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
        var watched: [String] = []
        var stopped = false
        init() { (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self) }
        func watch(convoID: String) { watched.append(convoID) }
        func stop() { stopped = true }
    }

    struct Offline: Error {}

    var capture: FakeCapture!
    var audio: FakeAudio!
    var player: FakePlayer!
    var sender: FakeSender!
    var feed: FakeFeed!
    var settings: VoiceSettings!
    var awake: [Bool] = []
    var defaultsName: String!

    override func setUp() async throws {
        capture = FakeCapture(); audio = FakeAudio(); player = FakePlayer(); sender = FakeSender(); feed = FakeFeed()
        defaultsName = "voice-runner-\(UUID().uuidString)"
        settings = VoiceSettings(defaults: UserDefaults(suiteName: defaultsName)!)
        awake = []
    }

    override func tearDown() async throws {
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    /// The microphone's start timeout in these tests: a value no engine
    /// timer uses, so `sleep` can tell it apart.
    nonisolated static let startTimeout: TimeInterval = 0.123

    /// Timers never fire by themselves in these tests: the test sends
    /// `timerFired` when it wants one to (`fire`). `startTimesOut` lets
    /// the one clock that is not an engine timer run out at once.
    func makeRunner(startTimesOut: Bool = false) -> VoiceModeRunner {
        VoiceModeRunner(capture: capture, audio: audio, player: player, sender: sender, feed: feed, settings: settings,
                        setScreenAwake: { [weak self] in self?.awake.append($0) },
                        captureStartTimeout: Self.startTimeout,
                        sleep: { seconds in
                            if startTimesOut, seconds == Self.startTimeout { return }
                            try await Task.sleep(for: .seconds(3_600))
                        })
    }

    /// Fires an engine timer as its clock would: with the token of its
    /// latest start. A timer that is not armed fails the test.
    func fire(_ runner: VoiceModeRunner, _ id: VoiceModeEngine.TimerID, file: StaticString = #filePath, line: UInt = #line) {
        guard let token = runner.state.timers[id] else {
            return XCTFail("\(id.rawValue) is not armed", file: file, line: line)
        }
        runner.send(.timerFired(id, token: token))
    }

    /// For "this happens": returns as soon as it has.
    func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func recordingFile(_ contents: String = "aac-bytes") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
        try! Data(contents.utf8).write(to: url)
        return url
    }

    /// Lets queued effects and their follow-on tasks run.
    func drain(_ runner: VoiceModeRunner) async {
        for _ in 0..<5 {
            await runner.settle()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testStartOpensTheMicrophoneInOrderAndWatchesTheConversation() async {
        settings.talkOver = false
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "Auth refactor", boxName: "aspen"))
        await drain(runner)
        XCTAssertEqual(runner.state.phase, .listening)
        XCTAssertEqual(runner.state.route, "Speaker")
        XCTAssertFalse(runner.state.config.talkOver, "the settings reach the engine")
        XCTAssertEqual(audio.log, ["activate"])
        XCTAssertEqual(capture.log, ["start record"])
        XCTAssertEqual(player.earcons, [.micOpen])
        XCTAssertEqual(feed.watched, ["c1"])
        XCTAssertEqual(awake, [true])
    }

    func testAnUtteranceIsUploadedTranscribedAndSentAsAVoiceNote() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        let file = recordingFile()
        capture.fileToReturn = file
        capture.continuation.yield(.speechStarted)
        capture.continuation.yield(.words("merge it"))
        capture.continuation.yield(.speechEnded)
        await drain(runner)
        fire(runner, .silence)
        await drain(runner)
        XCTAssertEqual(sender.uploads, [Data("aac-bytes".utf8)])
        XCTAssertEqual(sender.voiceNotes.map(\.ref), ["m-1"])
        XCTAssertEqual(sender.voiceNotes.first?.size, 9)
        XCTAssertEqual(sender.voiceNotes.first?.target, .conversation("c1"))
        XCTAssertEqual(runner.state.phase, .waiting)
        XCTAssertEqual(audio.log, ["activate", "release"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "sent: the file is gone")
        XCTAssertEqual(player.earcons, [.micOpen, .sent])
    }

    func testAReplyFromTheFeedIsSpokenThenTheMicrophoneOpens() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        fire(runner, .noSpeech)
        await drain(runner)
        feed.continuation.yield(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "Done."), convoTitle: "T")))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["Done."])
        XCTAssertEqual(runner.state.phase, .listening, "the clip finished, so it listens")
        XCTAssertEqual(capture.log.suffix(2), ["start monitor", "promote"])
    }

    func testStoppingAClipDoesNotReportItFinished() async {
        player.holds = true
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        fire(runner, .noSpeech)
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "A long reply."), convoTitle: "T")))
        await drain(runner)
        XCTAssertEqual(runner.state.phase, .speaking)
        runner.send(.tap)
        await drain(runner)
        XCTAssertEqual(player.stops, 1)
        XCTAssertEqual(runner.state.phase, .listening)
        XCTAssertNil(runner.state.playing)
    }

    func testDuckingReachesThePlayer() async {
        player.holds = true
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        fire(runner, .noSpeech)
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "A long reply."), convoTitle: "T")))
        runner.send(.speechStarted)
        fire(runner, .talkOverOnset)
        fire(runner, .talkOverWords)
        await drain(runner)
        XCTAssertEqual(player.ducks, [true, false])
    }

    func testOfflineKeepsTheNoteAndSendsItWhenTheConnectionReturns() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        let file = recordingFile()
        capture.fileToReturn = file
        sender.uploadError = Offline()
        runner.send(.words("merge it"))
        fire(runner, .silence)
        await drain(runner)
        XCTAssertEqual(player.spoken, ["No connection. I'll send it when you're back online."])
        XCTAssertEqual(player.earcons, [.micOpen, .error])
        XCTAssertEqual(runner.unsentCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "kept for the retry")
        sender.uploadError = nil
        runner.connectionRestored()
        await drain(runner)
        XCTAssertEqual(sender.voiceNotes.map(\.target), [.conversation("c1")])
        XCTAssertEqual(runner.unsentCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    /// Uploaded, then the socket dropped before the send: the engine is
    /// told, and the note still goes later.
    func testASendThatFailsAfterTheUploadIsAnnouncedAndRetried() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        capture.fileToReturn = recordingFile()
        sender.sendError = Offline()
        runner.send(.words("merge it"))
        fire(runner, .silence)
        await drain(runner)
        XCTAssertEqual(runner.unsentCount, 1)
        XCTAssertEqual(player.spoken, ["No connection. That wasn't sent."])
        sender.sendError = nil
        runner.connectionRestored()
        await drain(runner)
        XCTAssertEqual(sender.voiceNotes.count, 1)
        XCTAssertEqual(sender.uploads.count, 1, "not uploaded twice")
    }

    func testAnItemActionGoesThroughTheSenderAndTheRecordingIsDropped() async {
        let runner = makeRunner()
        let item = VoiceEntry.item(VoiceItem(id: "it_1", kind: .decision, convoID: "c2", title: "Ship it", labels: ["Go", "Wait"]),
                                   convoTitle: "Promo")
        runner.start(.queue(entries: [item], lastConvoID: "c1", lastTitle: "T", lastBoxName: nil))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["One thing needs you. A decision: Ship it. Options: Go, Wait."])
        let file = recordingFile()
        capture.fileToReturn = file
        sender.transcriptText = "Go."
        runner.send(.words("go"))
        fire(runner, .silence)
        await drain(runner)
        XCTAssertEqual(player.spoken.last, "Sending: Go.")
        XCTAssertEqual(runner.state.phase, .confirming)
        fire(runner, .confirm)
        await drain(runner)
        XCTAssertEqual(sender.itemActions.map(\.1), ["Go"])
        XCTAssertTrue(sender.voiceNotes.isEmpty, "a button press: the recording is not posted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testAFailedPromptReplyIsReported() async {
        let runner = makeRunner()
        let prompt = VoiceEntry.prompt(VoicePrompt(convoID: "c3", seq: 30, question: "Which?",
                                                   options: [.init(label: "A", value: "a"), .init(label: "B", value: "b")]),
                                       convoTitle: "Schema")
        runner.start(.queue(entries: [prompt], lastConvoID: nil, lastTitle: "", lastBoxName: nil))
        await drain(runner)
        sender.sendError = Offline()
        runner.send(.actionTapped("A"))
        await drain(runner)
        XCTAssertTrue(player.earcons.contains(.error))
    }

    func testAMicrophoneThatWillNotStartIsReported() async {
        capture.startError = Offline()
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["I can't use the microphone."])
    }

    func testAudioEventsReachTheEngine() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        audio.continuation.yield(.routeChanged("AirPods Pro"))
        audio.continuation.yield(.interruption(.began))
        await drain(runner)
        XCTAssertEqual(runner.state.route, "AirPods Pro")
        XCTAssertTrue(runner.state.paused)
    }

    func testEndingTearsDownAndTellsTheHost() async {
        let runner = makeRunner()
        var ended: VoiceModeEngine.EndReason?
        runner.onEnded = { ended = $0 }
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await drain(runner)
        runner.send(.end)
        await drain(runner)
        XCTAssertEqual(ended, .user)
        XCTAssertTrue(feed.stopped)
        XCTAssertEqual(awake, [true, false])
        XCTAssertEqual(capture.log, ["start record", "stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release"])
        XCTAssertEqual(runner.state.phase, .idle)
    }

    /// The screen that owns the runner may let go of it the moment it
    /// sends `end` (the cover is dismissed, the account signs out). The
    /// microphone is still closed, the audio given back, the feed stopped.
    func testEndingStillTearsDownWhenTheRunnerIsLetGoAtOnce() async {
        var runner: VoiceModeRunner? = makeRunner()
        runner?.start(.conversation(id: "c1", title: "T", boxName: nil))
        await drain(runner!)
        weak var gone = runner
        runner?.send(.end)
        runner = nil
        await waitUntil { self.feed.stopped }
        XCTAssertEqual(capture.log, ["start record", "stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release"])
        XCTAssertTrue(feed.stopped)
        XCTAssertEqual(awake, [true, false])
        await waitUntil { gone == nil }
        XCTAssertNil(gone, "and then it goes: nothing queued holds it for ever")
    }

    /// Ended before the microphone had its turn to open: it is not opened
    /// just to be closed (on a first run that would raise the permission
    /// prompt after End).
    func testEndingBeforeTheMicrophoneOpensDoesNotOpenIt() async {
        let runner = makeRunner()
        var ended: VoiceModeEngine.EndReason?
        runner.onEnded = { ended = $0 }
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        runner.send(.end)
        await drain(runner)
        XCTAssertEqual(ended, .user)
        XCTAssertEqual(capture.log, ["stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release"])
        // One runner, one sitting: it does not start again.
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        XCTAssertEqual(runner.state.phase, .idle)
    }

    // MARK: Timers

    /// A timer comes back with the token its start carried, which is how
    /// the engine tells the current one from one it has re-armed since.
    func testATimerFiresWithTheTokenItWasStartedWith() async {
        let runner = VoiceModeRunner(capture: capture, audio: audio, player: player, sender: sender, feed: feed,
                                     settings: settings, sleep: { seconds in
                                         // Only the no-speech timer runs out; the rest never do.
                                         if seconds == VoiceModeEngine.Config().noSpeechTimeout { return }
                                         try await Task.sleep(for: .seconds(3_600))
                                     })
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        XCTAssertEqual(runner.state.phase, .listening)
        await waitUntil { runner.state.phase == .waiting }
        XCTAssertEqual(runner.state.phase, .waiting, "nothing said: the microphone closed")
        XCTAssertNil(runner.state.timers[.noSpeech])
    }

    // MARK: A microphone that does not open

    /// Opening the microphone can wait on a prompt nobody answers or a
    /// model that never downloads. Everything else queues behind it, so it
    /// is given up on, said, and closed again if it ever does open.
    func testAMicrophoneThatNeverOpensIsGivenUpOn() async {
        capture.holdsStart = true
        let runner = makeRunner(startTimesOut: true)
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await waitUntil { self.player.spoken == ["I can't use the microphone."] && runner.state.phase == .waiting }
        XCTAssertEqual(player.spoken, ["I can't use the microphone."])
        XCTAssertEqual(runner.state.phase, .waiting)
        XCTAssertEqual(capture.log, ["start record"], "the start is still out")
        // A tap while it is: no second start on top of the first.
        runner.send(.tap)
        await waitUntil { self.player.spoken.count == 2 && runner.state.phase == .waiting }
        XCTAssertEqual(player.spoken.count, 2)
        XCTAssertEqual(capture.log, ["start record"])
        // It comes back at last: what it opened is closed, and the audio
        // it may have set going is let go of.
        await drain(runner)
        let releases = audio.log.filter { $0 == "release" }.count
        capture.releaseStart()
        await waitUntil { self.audio.log.filter { $0 == "release" }.count > releases }
        XCTAssertEqual(capture.log, ["start record", "started record", "stop keep=false"])
        XCTAssertEqual(audio.log.filter { $0 == "release" }.count, releases + 1)
        // And now a tap opens it.
        capture.holdsStart = false
        runner.send(.tap)
        await drain(runner)
        XCTAssertEqual(capture.log.last, "start record")
        XCTAssertEqual(runner.state.phase, .listening)
    }

    /// End must close the screen even while the microphone is opening.
    func testEndingDoesNotWaitForAMicrophoneThatIsStillOpening() async {
        capture.holdsStart = true
        let runner = makeRunner()
        var ended: VoiceModeEngine.EndReason?
        runner.onEnded = { ended = $0 }
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await waitUntil { self.capture.log == ["start record"] }
        runner.send(.end)
        await waitUntil { ended != nil }
        XCTAssertEqual(ended, .user, "ended with the start still out")
        XCTAssertEqual(capture.log, ["start record", "stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release"])
        // The start returns after voice mode has gone: closed again.
        capture.releaseStart()
        await waitUntil { self.audio.log.count == 3 }
        XCTAssertEqual(capture.log, ["start record", "stop keep=false", "started record", "stop keep=false"])
        XCTAssertEqual(audio.log, ["activate", "release", "release"])
    }

    // MARK: Playback

    /// `stopPlayback` acts at once; `play` waits its turn behind whatever
    /// is queued (here a microphone slow to close). A line stopped before
    /// its turn came must not then be said into a microphone that has
    /// moved on to listening.
    func testALineStoppedBeforeItsTurnIsNeverSaid() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        await drain(runner)
        capture.holdsStop = true
        // A reply lands while it listens and nothing has been said: the
        // recording is closed (held here), then the line is queued.
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "A long reply."), convoTitle: "T")))
        XCTAssertEqual(runner.state.phase, .speaking)
        await waitUntil { self.capture.log.last == "stop keep=false" }
        runner.send(.tap)
        XCTAssertEqual(runner.state.phase, .listening)
        capture.holdsStop = false
        capture.releaseStop()
        await drain(runner)
        XCTAssertEqual(player.spoken, [], "stopped before it began")
        XCTAssertEqual(runner.state.phase, .listening)
        XCTAssertEqual(capture.log.suffix(2), ["start monitor", "promote"])
    }

    /// Neither the clip nor the on-device voice could say the line. The
    /// loop must not stall in `speaking`: it carries on as if it were said.
    func testALineThatCouldNotBeSaidStillMovesOn() async {
        player.source = .failed
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        fire(runner, .noSpeech)
        await drain(runner)
        runner.send(.arrived(.reply(SpokenReply(convoID: "c1", seq: 9, short: "Done."), convoTitle: "T")))
        await drain(runner)
        XCTAssertEqual(player.spoken, ["Done."])
        XCTAssertEqual(runner.state.phase, .listening)
    }

    // MARK: Unsent notes

    /// The screen shows how many notes are waiting for a connection. A
    /// note leaving changes nothing in `state`, so the count itself must
    /// be observable or the line would stay up after the note has gone.
    func testTheUnsentCountIsObservable() async {
        let runner = makeRunner()
        runner.start(.conversation(id: "c1", title: "T", boxName: nil))
        capture.fileToReturn = recordingFile()
        sender.uploadError = Offline()
        runner.send(.words("merge it"))
        fire(runner, .silence)
        await drain(runner)
        XCTAssertEqual(runner.unsentCount, 1)
        final class Flag: @unchecked Sendable { var raised = false }
        let changed = Flag()
        withObservationTracking { _ = runner.unsentCount } onChange: { changed.raised = true }
        sender.uploadError = nil
        runner.connectionRestored()
        XCTAssertTrue(changed.raised, "the count's readers are told")
        await drain(runner)
        XCTAssertEqual(runner.unsentCount, 0)
    }
}

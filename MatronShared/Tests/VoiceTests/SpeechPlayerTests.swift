import AVFoundation
import XCTest
import MatronJournal
@testable import MatronVoice

/// Nothing here makes a sound: the journal, the clip output and the
/// on-device voice are all fakes.
@MainActor
final class SpeechPlayerTests: XCTestCase {
    final class FakeSynth: SpeechSynthesising, @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [(text: String, voice: String?)] = []
        private var _answered = 0
        private var _held: CheckedContinuation<Void, Never>?

        var voicesResult: Result<TTSVoices, Error> = .success(TTSVoices(voices: [], defaultVoiceID: nil))
        var clip: Result<Data, Error> = .success(Data("clip".utf8))
        /// A cancellable wait before the clip is returned.
        var delay: Duration = .zero
        /// A wait that carries on after the request's task is cancelled,
        /// as a transport that does not honour cancellation would.
        var uncancellableDelay: TimeInterval = 0
        /// Holds each request until `release()`.
        var holds = false
        var voiceRequests = 0

        var requests: [(text: String, voice: String?)] { lock.withLock { _requests } }
        /// Requests that have returned or thrown.
        var answered: Int { lock.withLock { _answered } }
        var isHolding: Bool { lock.withLock { _held != nil } }

        func release() {
            let held = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                defer { _held = nil }
                return _held
            }
            held?.resume()
        }

        func ttsVoices() async throws -> TTSVoices {
            voiceRequests += 1
            return try voicesResult.get()
        }

        func tts(text: String, voice: String?) async throws -> Data {
            lock.withLock { _requests.append((text, voice)) }
            defer { lock.withLock { _answered += 1 } }
            if holds {
                await withCheckedContinuation { continuation in lock.withLock { _held = continuation } }
            }
            if uncancellableDelay > 0 {
                let seconds = uncancellableDelay
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
                }
            }
            if delay > .zero { try await Task.sleep(for: delay) }
            return try clip.get()
        }
    }

    final class FakeOutput: ClipOutput {
        var played: [(audio: Data, rate: Double)] = []
        var effects: [Data] = []
        var volumes: [Float] = []
        var stops = 0
        var failure: Error?
        func play(_ audio: Data, rate: Double) async throws {
            if let failure { throw failure }
            played.append((audio, rate))
        }
        func playEffect(_ audio: Data) { effects.append(audio) }
        func stop() { stops += 1 }
        func setVolume(_ volume: Float) { volumes.append(volume) }
    }

    final class FakeLocal: LocalVoice {
        var spoken: [(text: String, rate: Double)] = []
        var volumes: [Float] = []
        func speak(_ text: String, rate: Double) async { spoken.append((text, rate)) }
        func stop() {}
        func setVolume(_ volume: Float) { volumes.append(volume) }
    }

    var synth: FakeSynth!
    var output: FakeOutput!
    var local: FakeLocal!
    var settings: VoiceSettings!
    var cache: SpeechClipCache!
    var defaultsName: String!

    override func setUp() async throws {
        synth = FakeSynth()
        output = FakeOutput()
        local = FakeLocal()
        defaultsName = "voice-player-\(UUID().uuidString)"
        settings = VoiceSettings(defaults: UserDefaults(suiteName: defaultsName)!)
        cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(defaultsName))
    }

    override func tearDown() async throws {
        cache.removeAll()
        UserDefaults().removePersistentDomain(forName: defaultsName)
    }

    func player(timeout: Duration = .seconds(2)) -> SpeechPlayer {
        SpeechPlayer(synth: synth, cache: cache, output: output, local: local, settings: settings, firstAudioTimeout: timeout)
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func testACloudClipIsPlayedAtTheChosenRateInTheChosenVoice() async {
        settings.voice = "en-GB-Emily"
        settings.rate = 1.2
        let source = await player().speak("The deploy finished.")
        XCTAssertEqual(source, .cloud)
        XCTAssertEqual(synth.requests.first?.text, "The deploy finished.")
        XCTAssertEqual(synth.requests.first?.voice, "en-GB-Emily")
        XCTAssertEqual(output.played.first?.audio, Data("clip".utf8))
        XCTAssertEqual(output.played.first?.rate, 1.2)
        XCTAssertTrue(local.spoken.isEmpty)
    }

    /// Any answer from `POST /tts` that is not a clip: the same text, on
    /// the device. None of them is remembered, a 404 or a 501 included:
    /// the next line asks the journal again.
    func testEveryFailureFallsBackToTheOnDeviceVoiceAndIsNotRemembered() async {
        let failures: [Error] = [
            TTSError.failed(status: 400, code: "bad_request"), TTSError.failed(status: 400, code: "unknown_voice"),
            TTSError.failed(status: 403, code: "forbidden"), TTSError.failed(status: 404, code: "not_found"),
            TTSError.failed(status: 413, code: nil), TTSError.failed(status: 429, code: "tts_budget_exceeded"),
            TTSError.failed(status: 501, code: "tts_unconfigured"), TTSError.failed(status: 502, code: "tts_failed"),
            TTSError.failed(status: 503, code: "tts_busy"), TTSError.failed(status: 200, code: nil),
            JournalAPIError.transport("offline"),
        ]
        let speaker = player()
        for (index, failure) in failures.enumerated() {
            synth.clip = .failure(failure)
            local.spoken = []
            let source = await speaker.speak("Sent.")
            XCTAssertEqual(source, .onDevice, "\(failure)")
            XCTAssertEqual(local.spoken.map(\.text), ["Sent."])
            XCTAssertEqual(synth.requests.count, index + 1, "asked again after \(failure)")
            XCTAssertFalse(speaker.cloudUnavailable, "\(failure)")
        }
        XCTAssertTrue(output.played.isEmpty)
        synth.clip = .success(Data("clip".utf8))
        let source = await speaker.speak("Sent.")
        XCTAssertEqual(source, .cloud, "the journal is back")
    }

    func testNoAudioWithinTheTimeoutFallsBack() async {
        synth.delay = .seconds(5)
        let source = await player(timeout: .milliseconds(50)).speak("Slow line.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(local.spoken.map(\.text), ["Slow line."])
    }

    /// The wait is the player's own: a request that does not stop when it
    /// is cancelled must not hold the line back past the timeout.
    func testARequestThatIgnoresCancellationDoesNotHoldTheLineBack() async {
        synth.uncancellableDelay = 3
        let source = await player(timeout: .milliseconds(50)).speak("Slow line.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(local.spoken.map(\.text), ["Slow line."])
        XCTAssertEqual(synth.answered, 0, "said on the device while the request was still out")
        XCTAssertTrue(output.played.isEmpty)
    }

    func testAClipThatWillNotPlayFallsBack() async {
        output.failure = ClipOutputError.cannotPlay
        let source = await player().speak("Garbled.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(local.spoken.map(\.text), ["Garbled."])
        // A clip that did not play is not kept, even for a fixed phrase.
        settings.voice = "en-GB-Harry"
        _ = await player().speak(VoicePhrases.sent)
        XCTAssertNil(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Harry"))
    }

    func testTheOnDeviceSettingNeverAsksTheJournal() async {
        settings.voice = VoiceSettings.onDevice
        let source = await player().speak("Hello.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    /// Only 404/501 from the voices route is remembered for the session.
    func testAJournalWithNoCloudVoiceIsRememberedButOtherFailuresAreNot() async {
        let speaker = player()
        synth.voicesResult = .failure(TTSError.failed(status: 503, code: "tts_busy"))
        await speaker.refreshVoices()
        XCTAssertFalse(speaker.cloudUnavailable)
        synth.voicesResult = .failure(JournalAPIError.transport("offline"))
        await speaker.refreshVoices()
        XCTAssertFalse(speaker.cloudUnavailable)
        _ = await speaker.speak("One.")
        XCTAssertEqual(synth.requests.count, 1)
        synth.voicesResult = .failure(TTSError.unavailable)
        await speaker.refreshVoices()
        XCTAssertTrue(speaker.cloudUnavailable)
        let source = await speaker.speak("Two.")
        XCTAssertEqual(source, .onDevice)
        XCTAssertEqual(synth.requests.count, 1, "not asked again")
    }

    func testVoicesAndTheJournalsDefaultAreKept() async {
        synth.voicesResult = .success(TTSVoices(voices: [TTSVoice(id: "en-GB-Emily", name: "Emily")], defaultVoiceID: "en-GB-Emily"))
        let speaker = player()
        XCTAssertEqual(speaker.voices.map(\.id), ["en-GB-Harry", "en-GB-Emily"], "the built-in pair until the journal answers")
        await speaker.refreshVoices()
        XCTAssertEqual(speaker.voices.map(\.id), ["en-GB-Emily"])
        _ = await speaker.speak("Hi.")
        XCTAssertEqual(synth.requests.first?.voice, "en-GB-Emily", "no choice made: the journal's default")
    }

    func testAFixedPhraseIsFetchedOnceThenPlayedFromThePhone() async {
        settings.voice = "en-GB-Harry"
        let speaker = player()
        let first = await speaker.speak(VoicePhrases.sent)
        let second = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual(first, .cloud)
        XCTAssertEqual(second, .cache)
        XCTAssertEqual(synth.requests.count, 1)
        // A reply is never kept.
        _ = await speaker.speak("The deploy finished.")
        _ = await speaker.speak("The deploy finished.")
        XCTAssertEqual(synth.requests.count, 3)
        // Another voice is another clip.
        settings.voice = "en-GB-Emily"
        let other = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual(other, .cloud)
    }

    /// Until the journal has said which voice is its default, a clip has
    /// no voice to be kept under: one kept as "the default" would go on
    /// playing in the old voice after the journal's default changed.
    func testNothingIsKeptUntilTheVoiceIsKnown() async {
        let speaker = player()
        let first = await speaker.speak(VoicePhrases.sent)
        let second = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual([first, second], [.cloud, .cloud])
        XCTAssertEqual(synth.requests.count, 2)
        synth.voicesResult = .success(TTSVoices(voices: VoiceSettings.builtInVoices, defaultVoiceID: "en-GB-Emily"))
        await speaker.refreshVoices()
        let third = await speaker.speak(VoicePhrases.sent)
        let fourth = await speaker.speak(VoicePhrases.sent)
        XCTAssertEqual([third, fourth], [.cloud, .cache])
        XCTAssertNotNil(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Emily"))
    }

    func testTextTooLongForTheJournalIsSaidOnTheDevice() async {
        let source = await player().speak(String(repeating: "word ", count: 500))
        XCTAssertEqual(source, .onDevice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    /// The journal counts UTF-16 units: 1,200 emoji are 1,200 characters
    /// here and 2,400 there.
    func testLengthIsCountedAsTheJournalCountsIt() async {
        let source = await player().speak(String(repeating: "\u{1F600}", count: 1_200))
        XCTAssertEqual(source, .onDevice)
        XCTAssertTrue(synth.requests.isEmpty)
    }

    func testAnEmptyLineSaysNothing() async {
        for text in ["", "  \n"] {
            let source = await player().speak(text)
            XCTAssertEqual(source, .stopped)
        }
        XCTAssertTrue(synth.requests.isEmpty)
        XCTAssertTrue(output.played.isEmpty)
        XCTAssertTrue(local.spoken.isEmpty)
    }

    func testALineOvertakenWhileItsClipWasOnItsWaySaysNothing() async {
        synth.holds = true
        let speaker = player()
        async let first = speaker.speak("First.")
        await waitUntil { self.synth.isHolding }
        XCTAssertTrue(synth.isHolding)
        speaker.stop()
        // The request is still out: a stopped line does not wait for it.
        let source = await first
        XCTAssertEqual(source, .stopped)
        XCTAssertEqual(synth.answered, 0)
        synth.release()
        await waitUntil { self.synth.answered == 1 }
        XCTAssertTrue(output.played.isEmpty)
        XCTAssertTrue(local.spoken.isEmpty)
    }

    func testTheNextLineDoesNotWaitForTheOneItOvertook() async {
        synth.holds = true
        let speaker = player()
        async let first = speaker.speak("First.")
        await waitUntil { self.synth.isHolding }
        synth.holds = false
        let second = await speaker.speak("Second.")
        let overtaken = await first
        XCTAssertEqual(second, .cloud)
        XCTAssertEqual(overtaken, .stopped)
        XCTAssertEqual(output.played.count, 1)
        synth.release()
        await waitUntil { self.synth.answered == 2 }
        XCTAssertEqual(output.played.count, 1, "the late clip goes nowhere")
    }

    func testTheOnDeviceRateStaysNearNormal() {
        let normal = SynthesizerLocalVoice.utteranceRate(1)
        XCTAssertEqual(normal, AVSpeechUtteranceDefaultSpeechRate)
        XCTAssertEqual(SynthesizerLocalVoice.utteranceRate(1.5), normal + 0.1, accuracy: 0.001)
        XCTAssertEqual(SynthesizerLocalVoice.utteranceRate(0.8), normal - 0.04, accuracy: 0.001)
    }

    func testDuckingAndEarcons() {
        let speaker = player()
        speaker.setDucked(true)
        speaker.setDucked(false)
        XCTAssertEqual(output.volumes, [0.2, 1])
        XCTAssertEqual(local.volumes, [0.2, 1])
        speaker.play(.sent)
        XCTAssertEqual(output.effects, [EarconSynth.wav(.sent)])
    }
}

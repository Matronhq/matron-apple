import Foundation
import MatronJournal
import os

/// Where encoded audio (a cloud clip, an earcon) is played. PR 2's
/// `PlayerClipOutput` is a plain `AVAudioPlayer`; voice mode proper plays
/// through the capture engine instead, so the echo canceller can take the
/// agent's voice back out of the microphone (`VoiceAudioEngine`).
@MainActor
public protocol ClipOutput: AnyObject {
    /// Plays `audio` (MP3 or WAV) to its end. Returns early, without
    /// throwing, when `stop()` is called. Throws when it cannot be played.
    func play(_ audio: Data, rate: Double) async throws
    /// Plays a short sound over whatever else is playing; does not wait.
    func playEffect(_ audio: Data)
    func stop()
    func setVolume(_ volume: Float)
}

/// The on-device voice: the fallback when the journal has no clip to give.
@MainActor
public protocol LocalVoice: AnyObject {
    /// Speaks `text` to its end, or until `stop()`.
    func speak(_ text: String, rate: Double) async
    func stop()
    func setVolume(_ volume: Float)
}

/// Says a line (spec 2026-10-03 §3, "Playing"): the journal's clip, and on
/// ANY failure to get one — a status that is not 200, no network, or no
/// audio within two seconds — the same text in the on-device voice. Fixed
/// phrases are kept on the phone after first use.
@MainActor
public final class SpeechPlayer {
    public enum Source: String, Equatable, Sendable { case cloud, cache, onDevice, stopped }

    /// How loud a clip is while someone may be talking over it.
    public static let duckedVolume: Float = 0.2

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-player")

    private let synth: any SpeechSynthesising
    private let cache: SpeechClipCache
    private let output: any ClipOutput
    private let local: any LocalVoice
    private let settings: VoiceSettings
    private let firstAudioTimeout: Duration
    /// Bumped by every `speak` and `stop`: a line that was overtaken while
    /// its clip was still on its way says nothing when the clip lands.
    private var generation = 0
    /// The request `fetch` is waiting on, if any: `stop()` and the next
    /// `speak` answer it with nothing, so neither waits for the journal.
    private var pendingAnswer: AsyncStream<Data?>.Continuation?

    /// `GET /tts/voices` answered 404 or 501: this journal has no cloud
    /// voice, and nothing asks it again this session. No other failure is
    /// remembered, and no answer from `POST /tts` is.
    public private(set) var cloudUnavailable = false
    public private(set) var voices: [TTSVoice] = VoiceSettings.builtInVoices
    public private(set) var defaultVoiceID: String?

    public init(synth: any SpeechSynthesising, cache: SpeechClipCache, output: any ClipOutput, local: any LocalVoice,
                settings: VoiceSettings, firstAudioTimeout: Duration = .seconds(2)) {
        self.synth = synth
        self.cache = cache
        self.output = output
        self.local = local
        self.settings = settings
        self.firstAudioTimeout = firstAudioTimeout
    }

    /// Asks the journal which voices it has. Call when voice mode or its
    /// settings open.
    public func refreshVoices() async {
        do {
            let answer = try await synth.ttsVoices()
            if !answer.voices.isEmpty { voices = answer.voices }
            defaultVoiceID = answer.defaultVoiceID
            cloudUnavailable = false
        } catch TTSError.unavailable {
            cloudUnavailable = true
        } catch {
            Self.logger.info("voices: \(String(describing: error), privacy: .public)")
        }
    }

    /// Speaks `text` and returns when it has been said, or was stopped.
    @discardableResult
    public func speak(_ text: String) async -> Source {
        generation += 1
        let mine = generation
        pendingAnswer?.yield(nil)
        output.stop()
        local.stop()
        // Nothing to say: the journal would refuse it, and the on-device
        // voice may never report an empty line as finished.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .stopped }
        let rate = settings.rate
        // The journal counts UTF-16 units, as JavaScript does.
        guard !settings.usesOnDeviceVoice, !cloudUnavailable, text.utf16.count <= JournalAPI.ttsTextLimit else {
            return await speakLocally(text, rate: rate, generation: mine)
        }
        // Clips are kept only under a voice's own id. Before the journal
        // has said which voice is its default nothing is kept, so a clip
        // can never outlive a change of that default.
        let voice = settings.voice ?? defaultVoiceID
        if let voice, let cached = cache.clip(text: text, voice: voice) {
            do {
                try await output.play(cached, rate: rate)
                return mine == generation ? .cache : .stopped
            } catch {
                Self.logger.info("cached clip would not play; asking again")
            }
        }
        guard mine == generation else { return .stopped }
        let audio = await fetch(text, voice: voice)
        guard mine == generation else { return .stopped }
        guard let audio else { return await speakLocally(text, rate: rate, generation: mine) }
        do {
            try await output.play(audio, rate: rate)
            if let voice { cache.store(audio, text: text, voice: voice) }
            return mine == generation ? .cloud : .stopped
        } catch {
            guard mine == generation else { return .stopped }
            return await speakLocally(text, rate: rate, generation: mine)
        }
    }

    public func stop() {
        generation += 1
        pendingAnswer?.yield(nil)
        output.stop()
        local.stop()
    }

    public func setDucked(_ ducked: Bool) {
        let volume = ducked ? Self.duckedVolume : 1
        output.setVolume(volume)
        local.setVolume(volume)
    }

    public func play(_ earcon: VoiceModeEngine.Earcon) {
        output.playEffect(EarconSynth.wav(earcon))
    }

    private func speakLocally(_ text: String, rate: Double, generation mine: Int) async -> Source {
        await local.speak(text, rate: rate)
        return mine == generation ? .onDevice : .stopped
    }

    /// The clip, or `nil` on any error or when none has arrived in time.
    ///
    /// The wait is this method's own, not the request's: the request and
    /// the clock each post to one stream and the first to post wins. (A
    /// task group would wait for the cancelled request to return before
    /// giving up, so a transport that is slow to notice cancellation
    /// would hold the line back past the two seconds.) `stop()` and the
    /// next `speak` post too, so a stopped line returns at once. The
    /// losers are cancelled and whatever they post afterwards goes nowhere.
    private func fetch(_ text: String, voice: String?) async -> Data? {
        let synth = self.synth
        let timeout = firstAudioTimeout
        let (answers, answer) = AsyncStream<Data?>.makeStream()
        pendingAnswer = answer
        let request = Task {
            do {
                answer.yield(try await synth.tts(text: text, voice: voice))
            } catch {
                Self.logger.info("tts: \(String(describing: error), privacy: .public)")
                answer.yield(nil)
            }
        }
        let clock = Task {
            try? await Task.sleep(for: timeout)
            answer.yield(nil)
        }
        var first: Data?
        for await clip in answers {
            first = clip
            break
        }
        answer.finish()
        request.cancel()
        clock.cancel()
        return first
    }
}

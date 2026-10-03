import XCTest
@testable import MatronVoice

final class VoiceSupportTests: XCTestCase {
    // MARK: SpeechClipCache

    func testOnlyFixedPhrasesAreKept() {
        let cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { cache.removeAll() }
        cache.store(Data("a".utf8), text: VoicePhrases.sent, voice: "en-GB-Harry")
        cache.store(Data("b".utf8), text: "The deploy finished.", voice: "en-GB-Harry")
        XCTAssertEqual(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Harry"), Data("a".utf8))
        XCTAssertNil(cache.clip(text: "The deploy finished.", voice: "en-GB-Harry"))
        XCTAssertNil(cache.clip(text: VoicePhrases.sent, voice: "en-GB-Emily"), "keyed by voice as well as text")
        XCTAssertTrue(SpeechClipCache.isCacheable("Three things need you."))
        XCTAssertFalse(SpeechClipCache.isCacheable("Sending: Go."))
    }

    /// What is kept is `VoicePhrases.fixed` itself, not a copy of it: a
    /// phrase added there is kept here, and the cache holds the whole list
    /// in every voice the settings offer without evicting any of it.
    @MainActor
    func testEveryFixedPhraseIsKeptAndTheWholeListFitsInEveryVoice() {
        XCTAssertFalse(VoicePhrases.fixed.isEmpty)
        for phrase in VoicePhrases.fixed {
            XCTAssertTrue(SpeechClipCache.isCacheable(phrase), phrase)
        }
        XCTAssertTrue(SpeechClipCache.isCacheable(VoicePhrases.moreHint))
        XCTAssertTrue(SpeechClipCache.isCacheable(VoicePhrases.goOn))
        XCTAssertTrue(SpeechClipCache.isCacheable(VoicePhrases.couldNotHear))
        let cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { cache.removeAll() }
        let voices = VoiceSettings.builtInVoices.map(\.id)
        XCTAssertLessThanOrEqual(Set(VoicePhrases.fixed).count * voices.count, cache.limit)
        for voice in voices {
            for phrase in VoicePhrases.fixed { cache.store(Data("x".utf8), text: phrase, voice: voice) }
        }
        for voice in voices {
            for phrase in VoicePhrases.fixed { XCTAssertNotNil(cache.clip(text: phrase, voice: voice), "\(voice): \(phrase)") }
        }
    }

    func testTheKeyIsAHashOfVoiceAndText() {
        XCTAssertEqual(SpeechClipCache.key(text: "Sent.", voice: "v").count, 64)
        XCTAssertNotEqual(SpeechClipCache.key(text: "Sent.", voice: "a"), SpeechClipCache.key(text: "Sent.", voice: "b"))
        XCTAssertEqual(SpeechClipCache.key(text: "Sent.", voice: "a"), SpeechClipCache.key(text: "Sent.", voice: "a"))
    }

    func testTheOldestClipsGoWhenTheCacheIsFull() {
        let cache = SpeechClipCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), limit: 2)
        defer { cache.removeAll() }
        let phrases = [VoicePhrases.sent, VoicePhrases.cancelled, VoicePhrases.denied]
        for (index, phrase) in phrases.enumerated() {
            cache.store(Data("x".utf8), text: phrase, voice: "v")
            // Modification dates a second apart, so "oldest" is well defined.
            let url = cache.url(text: phrase, voice: "v")
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + index))],
                                                   ofItemAtPath: url.path)
        }
        cache.store(Data("x".utf8), text: VoicePhrases.notSent, voice: "v")
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: cache.directory.path)) ?? []
        XCTAssertEqual(kept.count, 2)
        XCTAssertNil(cache.clip(text: VoicePhrases.sent, voice: "v"))
        XCTAssertNotNil(cache.clip(text: VoicePhrases.notSent, voice: "v"))
    }

    // MARK: EarconSynth

    func testEarconsAreShortValidWavFiles() {
        for earcon in VoiceModeEngine.Earcon.allCases {
            let wav = EarconSynth.wav(earcon)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
            let samples = EarconSynth.samples(earcon)
            XCTAssertEqual(wav.count, 44 + samples.count * 2)
            XCTAssertLessThan(EarconSynth.duration(earcon), 0.35)
            XCTAssertEqual(samples.first, 0, "fades in from silence")
            XCTAssertLessThanOrEqual(samples.map { abs(Int($0)) }.max() ?? 0, Int(Double(Int16.max) * 0.36))
        }
        XCTAssertNotEqual(EarconSynth.wav(.micOpen), EarconSynth.wav(.error))
    }

    // MARK: VoiceSettings

    @MainActor
    func testSettingsDefaultPersistAndClamp() {
        let name = "voice-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let settings = VoiceSettings(defaults: defaults)
        XCTAssertNil(settings.voice); XCTAssertEqual(settings.rate, 1)
        XCTAssertTrue(settings.talkOver); XCTAssertTrue(settings.offerMore)
        XCTAssertFalse(settings.usesOnDeviceVoice); XCTAssertFalse(settings.debugTools)
        settings.voice = VoiceSettings.onDevice
        settings.rate = 1.3
        settings.talkOver = false
        settings.offerMore = false
        settings.debugTools = true
        let reloaded = VoiceSettings(defaults: defaults)
        XCTAssertTrue(reloaded.usesOnDeviceVoice); XCTAssertEqual(reloaded.rate, 1.3)
        XCTAssertFalse(reloaded.talkOver); XCTAssertFalse(reloaded.offerMore); XCTAssertTrue(reloaded.debugTools)
        let config = reloaded.engineConfig()
        XCTAssertFalse(config.talkOver); XCTAssertFalse(config.offerMore)
        // Nothing else in the engine's configuration is a setting.
        var expected = VoiceModeEngine.Config()
        expected.talkOver = false
        expected.offerMore = false
        XCTAssertEqual(config, expected)
        defaults.set(9.0, forKey: "matron.voice.rate")
        XCTAssertEqual(VoiceSettings(defaults: defaults).rate, 1.5, "a stored rate out of range is clamped")
        // The spike's fallback: off until the user turns it on.
        let fresh = UserDefaults(suiteName: name + "-b")!
        defer { UserDefaults().removePersistentDomain(forName: name + "-b") }
        XCTAssertFalse(VoiceSettings(defaults: fresh, talkOverDefault: false).talkOver)
    }
}

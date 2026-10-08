import AVFoundation
import XCTest
@testable import MatronVoice

/// The parts of capture that need no microphone.
final class VoiceCaptureTests: XCTestCase {
    static let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// A buffer of `seconds` at 16 kHz, every sample set to `value`.
    func buffer(_ seconds: Double, value: Float = 0) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = value }
        return buffer
    }

    func testPreRollKeepsTheLastHalfSecond() {
        var preRoll = PreRollBuffer(seconds: 0.5)
        XCTAssertEqual(preRoll.duration, 0)
        for index in 0..<10 { preRoll.append(buffer(0.1, value: Float(index))) }
        XCTAssertEqual(preRoll.duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(preRoll.buffers.map { $0.floatChannelData![0][0] }, [5, 6, 7, 8, 9], "the newest five")
        let drained = preRoll.drain()
        XCTAssertEqual(drained.count, 5)
        XCTAssertEqual(preRoll.duration, 0)
    }

    /// One buffer longer than the window is kept whole rather than cut.
    func testPreRollNeverDropsItsOnlyBuffer() {
        var preRoll = PreRollBuffer(seconds: 0.5)
        preRoll.append(buffer(2))
        XCTAssertEqual(preRoll.buffers.count, 1)
        preRoll.append(buffer(0.6))
        XCTAssertEqual(preRoll.buffers.count, 1, "the newer buffer covers the window by itself")
        XCTAssertEqual(preRoll.duration, 0.6, accuracy: 0.001)
    }

    func testCopyIsIndependentOfItsSource() throws {
        let source = buffer(0.1, value: 0.25)
        let copy = try XCTUnwrap(copyOf(source))
        source.floatChannelData![0][0] = 0.9
        XCTAssertEqual(copy.frameLength, source.frameLength)
        XCTAssertEqual(copy.floatChannelData![0][0], 0.25)
    }

    func testWordsWhileRecordingAddUpAcrossSegments() {
        var words = WordsAccumulator()
        words.reset(recording: true)
        XCTAssertEqual(words.add("merge", isFinal: false), "merge")
        XCTAssertEqual(words.add("merge it", isFinal: false), "merge it")
        XCTAssertEqual(words.add("Merge it.", isFinal: true), "Merge it.")
        XCTAssertEqual(words.add("when the", isFinal: false), "Merge it. when the")
        XCTAssertEqual(words.add("When the tests pass.", isFinal: true), "Merge it. When the tests pass.")
    }

    /// Under a clip only the segment in progress counts; when talking over
    /// turns into an utterance, that segment is its start.
    func testWordsWhileMonitoringAreOnlyTheSegmentInProgress() {
        var words = WordsAccumulator()
        words.reset(recording: false)
        XCTAssertEqual(words.add("The deploy finished.", isFinal: true), "The deploy finished.")
        XCTAssertEqual(words.add("actually", isFinal: false), "actually")
        words.promote()
        XCTAssertEqual(words.add("actually wait", isFinal: false), "actually wait")
        XCTAssertEqual(words.add("Actually wait.", isFinal: true), "Actually wait.")
        XCTAssertEqual(words.add("for the tests", isFinal: false), "Actually wait. for the tests")
        words.reset(recording: false)
        XCTAssertEqual(words.text, "")
    }

    @MainActor
    func testEncodedClipsOpenAsAudioFiles() throws {
        let file = try VoiceAudioEngine.audioFile(EarconSynth.wav(.sent))
        XCTAssertEqual(file.processingFormat.sampleRate, 24_000)
        XCTAssertEqual(Double(file.length) / 24_000, EarconSynth.duration(.sent), accuracy: 0.001)
        XCTAssertThrowsError(try VoiceAudioEngine.audioFile(Data("not audio".utf8)))
    }

    /// What the on-device voice renders (16-bit, 22.05 kHz, in several
    /// buffers) becomes one buffer in the engine's play format, of the
    /// same duration. A buffer in some other format is left out.
    @MainActor
    func testRenderedSpeechIsConvertedToThePlayFormat() throws {
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 22_050, channels: 1, interleaved: true)!
        func chunk(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: integer, frameCapacity: frames)!
            buffer.frameLength = frames
            for index in 0..<Int(frames) { buffer.int16ChannelData![0][index] = index % 2 == 0 ? 8_000 : -8_000 }
            return buffer
        }
        let converted = try XCTUnwrap(VoiceAudioEngine.inPlayFormat([chunk(11_025), chunk(11_025), buffer(0.3)]))
        XCTAssertEqual(converted.format, VoiceAudioEngine.playFormat)
        XCTAssertEqual(Double(converted.frameLength) / 48_000, 1.0, accuracy: 0.02)
        XCTAssertNil(VoiceAudioEngine.inPlayFormat([]))
        let empty = AVAudioPCMBuffer(pcmFormat: integer, frameCapacity: 16)!
        XCTAssertNil(VoiceAudioEngine.inPlayFormat([empty]))
    }

    /// The first build on a phone crashed at its first sound: the graph
    /// was rewired in the clip's format while the engine ran. This runs
    /// the production wiring offline (no hardware, no sound) and plays a
    /// real clip through it without touching a connection.
    @MainActor
    func testAClipPlaysThroughTheGraphWithoutRewiringIt() throws {
        let clip = try XCTUnwrap(VoiceAudioEngine.inPlayFormat(
            VoiceAudioEngine.pcm(of: VoiceAudioEngine.audioFile(EarconSynth.wav(.sent)))))
        XCTAssertEqual(clip.format, VoiceAudioEngine.playFormat)
        XCTAssertEqual(Double(clip.frameLength) / 48_000, EarconSynth.duration(.sent), accuracy: 0.01)

        let engine = AVAudioEngine()
        let voice = AVAudioPlayerNode(), effects = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
        let output = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 4_096)
        VoiceAudioEngine.wirePlayback(in: engine, voice: voice, pitch: pitch, effects: effects)
        try engine.start()
        defer { engine.stop() }
        pitch.rate = 1.2
        // Both nodes, and twice on the voice: a second clip needs no new
        // connection either.
        voice.scheduleBuffer(clip)
        voice.scheduleBuffer(clip)
        effects.scheduleBuffer(clip)
        voice.play()
        effects.play()
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        var peak: Float = 0
        for _ in 0..<12 {
            XCTAssertEqual(try engine.renderOffline(4_096, to: rendered), .success)
            let samples = UnsafeBufferPointer(start: rendered.floatChannelData![0], count: Int(rendered.frameLength))
            peak = max(peak, samples.map(abs).max() ?? 0)
        }
        XCTAssertGreaterThan(peak, 0.05, "the clip came out of the mixer")
    }

    /// The synthesizer ends a line with an empty buffer; a line stopped
    /// mid-render is handed over at once, with nothing to play, and a late
    /// ending from the synthesizer is then ignored.
    func testARenderedLineIsHandedOverOnceWhenItEndsOrIsStopped() async {
        let empty = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: 16)!
        let whole: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            let rendered = RenderedSpeech(continuation)
            rendered.take(buffer(0.1))
            rendered.take(buffer(0.1))
            rendered.take(empty)
            rendered.abandon()
        }
        XCTAssertEqual(whole.count, 2)
        let stopped: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            let rendered = RenderedSpeech(continuation)
            rendered.take(buffer(0.1))
            rendered.abandon()
            rendered.take(empty)
        }
        XCTAssertTrue(stopped.isEmpty)
    }

    /// Seconds of audio in a recorded file.
    func seconds(of url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// A hands-free Bluetooth microphone runs at 16 kHz, where the encoder
    /// refuses the 64 kbit/s a voice note is written at elsewhere: the
    /// recording must still open and hold what was said.
    @available(macOS 15, *)
    func testAnUtteranceIsRecordedAtAHandsFreeMicrophonesRate() throws {
        let core = CaptureCore()
        core.begin(record: true, format: Self.format)
        for _ in 0..<10 { core.append(buffer(0.1, value: 0.1)) }
        let url = try XCTUnwrap(core.finish(keep: true))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.pathExtension, "m4a")
        XCTAssertEqual(try seconds(of: url), 1, accuracy: 0.2)
        XCTAssertNil(CaptureCore.fileSettings(for: Self.format)[AVEncoderBitRateKey])
        let wide = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        XCTAssertEqual(CaptureCore.fileSettings(for: wide)[AVEncoderBitRateKey] as? Int, 64_000)
    }

    /// Monitoring writes nothing; when it becomes a recording the file
    /// starts with the half second already heard.
    @available(macOS 15, *)
    func testPromotingAMonitorStartsTheFileWithThePreRoll() throws {
        let core = CaptureCore()
        core.begin(record: false, format: Self.format)
        for _ in 0..<10 { core.append(buffer(0.1, value: 0.1)) }
        XCTAssertNil(core.finish(keep: true), "nothing is written while only monitoring")
        core.begin(record: false, format: Self.format)
        for _ in 0..<10 { core.append(buffer(0.1, value: 0.1)) }
        core.promote()
        for _ in 0..<5 { core.append(buffer(0.1, value: 0.1)) }
        let url = try XCTUnwrap(core.finish(keep: true))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try seconds(of: url), 1, accuracy: 0.2)
    }
}

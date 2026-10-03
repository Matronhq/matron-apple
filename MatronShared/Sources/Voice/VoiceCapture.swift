import AVFoundation
import Foundation
import Speech
import os

public enum VoiceCaptureError: Error, Equatable, Sendable {
    case microphoneDenied
    case noInput
    /// The on-device recogniser does not support the locale, or its model
    /// could not be installed.
    case recogniserUnavailable
}

/// The last half second of microphone audio, kept while the engine only
/// monitors, so that when talking over a clip turns into an utterance its
/// first word is not clipped (spec 2026-10-03 §3, "Talking over the agent").
struct PreRollBuffer {
    let seconds: TimeInterval
    private(set) var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0

    init(seconds: TimeInterval = 0.5) {
        self.seconds = seconds
    }

    var duration: TimeInterval {
        guard let rate = buffers.first?.format.sampleRate, rate > 0 else { return 0 }
        return Double(frames) / rate
    }

    mutating func append(_ buffer: AVAudioPCMBuffer) {
        buffers.append(buffer)
        frames += buffer.frameLength
        let limit = AVAudioFrameCount(seconds * buffer.format.sampleRate)
        // Drop from the front while what is left still covers the window.
        while let first = buffers.first, buffers.count > 1, frames - first.frameLength >= limit {
            frames -= first.frameLength
            buffers.removeFirst()
        }
    }

    mutating func drain() -> [AVAudioPCMBuffer] {
        defer { removeAll() }
        return buffers
    }

    mutating func removeAll() {
        buffers = []
        frames = 0
    }
}

/// The recogniser's words for the utterance so far. While monitoring, only
/// the segment in progress counts (what was said under earlier parts of a
/// clip is not part of what he says now); while recording, finished
/// segments add up.
struct WordsAccumulator {
    var recording = false
    private var finished = ""
    private var current = ""

    var text: String {
        [finished, current].filter { !$0.isEmpty }.joined(separator: " ")
    }

    mutating func add(_ segment: String, isFinal: Bool) -> String {
        let segment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if isFinal, recording {
            finished = [finished, segment].filter { !$0.isEmpty }.joined(separator: " ")
            current = ""
        } else {
            current = segment
        }
        return text
    }

    /// Monitoring becomes recording: what is being said now is its start.
    mutating func promote() {
        recording = true
        finished = ""
    }

    mutating func reset(recording: Bool) {
        self.recording = recording
        finished = ""
        current = ""
    }
}

/// A copy of `buffer`: the engine may reuse a tap's buffer after the
/// callback returns.
func copyOf(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
    copy.frameLength = buffer.frameLength
    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
    for (from, to) in zip(source, destination) {
        guard let fromData = from.mData, let toData = to.mData else { continue }
        memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
    }
    return copy
}

/// Writes the microphone to a voice-note file. Called from the audio
/// thread (`append`) and the main actor (everything else).
@available(iOS 26, macOS 26, *)
final class CaptureCore: @unchecked Sendable {
    private let lock = NSLock()
    private var preRoll = PreRollBuffer()
    private var file: AVAudioFile?
    private var url: URL?
    private var format: AVAudioFormat?

    func begin(record: Bool, format: AVAudioFormat) {
        lock.lock()
        defer { lock.unlock() }
        self.format = format
        preRoll.removeAll()
        if record { openFile() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let file {
            try? file.write(from: buffer)
        } else if let copy = copyOf(buffer) {
            preRoll.append(copy)
        }
    }

    /// Starts the file with the half second already heard.
    func promote() {
        lock.lock()
        defer { lock.unlock() }
        guard file == nil else { return }
        openFile()
        for buffer in preRoll.drain() { try? file?.write(from: buffer) }
    }

    func finish(keep: Bool) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        file?.close()
        file = nil
        preRoll.removeAll()
        let finished = url
        url = nil
        guard let finished else { return nil }
        if keep { return finished }
        try? FileManager.default.removeItem(at: finished)
        return nil
    }

    /// The voice-note format `VoiceRecorder` writes (AAC in an `.m4a`,
    /// mono, 64 kbit/s), at the microphone's own sample rate: under voice
    /// processing that is whatever the echo canceller runs at, and
    /// resampling it to 44.1 kHz would add nothing.
    ///
    /// The bit rate is asked for only where the encoder takes it. Below
    /// 22.05 kHz (a hands-free Bluetooth microphone is 8 or 16 kHz) it
    /// refuses 64 kbit/s and the file would not open at all, so there the
    /// rate is left to the encoder.
    static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        if format.sampleRate >= 22_050 { settings[AVEncoderBitRateKey] = 64_000 }
        return settings
    }

    private func openFile() {
        guard let format else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        file = try? AVAudioFile(forWriting: url, settings: Self.fileSettings(for: format),
                                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.url = file == nil ? nil : url
    }
}

/// The on-device recogniser (spec §3, "Listening"): `SpeechDetector` says
/// whether someone is speaking, `SpeechTranscriber` gives rough words.
/// Its words are never sent to the agent: they decide end of speech,
/// talking over a clip, and commands.
///
/// API as declared in the iOS 26 SDK's `Speech.swiftinterface` and
/// described at https://developer.apple.com/documentation/speech/speechanalyzer
/// and https://developer.apple.com/documentation/speech/speechdetector
/// ("This module only functions in conjunction with a SpeechTranscriber or
/// DictationTranscriber module").
@available(iOS 26, macOS 26, *)
final class SpeechListener: @unchecked Sendable {
    let events: AsyncStream<VoiceCaptureEvent>
    private let eventsContinuation: AsyncStream<VoiceCaptureEvent>.Continuation
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let lock = NSLock()
    private var words = WordsAccumulator()
    private var tasks: [Task<Void, Never>] = []

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-listener")

    static func make(locale: Locale, inputFormat: AVAudioFormat, recording: Bool) async throws -> SpeechListener {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceCaptureError.recogniserUnavailable
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .progressiveTranscription)
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
        let modules: [any SpeechModule] = [detector, transcriber]
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                try await request.downloadAndInstall()
            }
        } catch {
            logger.error("assets: \(error.localizedDescription, privacy: .public)")
            throw VoiceCaptureError.recogniserUnavailable
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules, considering: inputFormat) else {
            throw VoiceCaptureError.recogniserUnavailable
        }
        // Lingering: the models stay loaded between one opening of the
        // microphone and the next.
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let listener = SpeechListener(analyzer: analyzer, input: input, analyzerFormat: format, inputFormat: inputFormat,
                                      recording: recording)
        try await analyzer.start(inputSequence: stream)
        listener.listen(detector: detector, transcriber: transcriber)
        return listener
    }

    private init(analyzer: SpeechAnalyzer, input: AsyncStream<AnalyzerInput>.Continuation, analyzerFormat: AVAudioFormat,
                 inputFormat: AVAudioFormat, recording: Bool) {
        self.analyzer = analyzer
        self.input = input
        self.analyzerFormat = analyzerFormat
        self.converter = inputFormat == analyzerFormat ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)
        (events, eventsContinuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self)
        words.reset(recording: recording)
    }

    private func listen(detector: SpeechDetector, transcriber: SpeechTranscriber) {
        let continuation = eventsContinuation
        tasks.append(Task {
            var speaking = false
            do {
                for try await result in detector.results where result.speechDetected != speaking {
                    speaking = result.speechDetected
                    continuation.yield(speaking ? .speechStarted : .speechEnded)
                }
            } catch {
                if !(error is CancellationError) { continuation.yield(.failed) }
            }
        })
        tasks.append(Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    continuation.yield(.words(self.heard(String(result.text.characters), isFinal: result.isFinal)))
                }
            } catch {
                if !(error is CancellationError) { continuation.yield(.failed) }
            }
        })
    }

    private func heard(_ segment: String, isFinal: Bool) -> String {
        lock.lock()
        defer { lock.unlock() }
        return words.add(segment, isFinal: isFinal)
    }

    func promote() {
        lock.lock()
        words.promote()
        lock.unlock()
    }

    /// From the audio thread: one microphone buffer for the recogniser.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            if let copy = copyOf(buffer) { input.yield(AnalyzerInput(buffer: copy)) }
            return
        }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
        var handed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
    }

    func finish() async {
        input.finish()
        for task in tasks { task.cancel() }
        await analyzer.cancelAndFinishNow()
        eventsContinuation.finish()
    }
}

/// The microphone for voice mode: the capture engine's input, written to a
/// voice-note file and fed to the on-device recogniser. `VoiceRecorder` is
/// unchanged and keeps serving ordinary voice notes.
@available(iOS 26, macOS 26, *)
@MainActor
public final class VoiceCapture: VoiceCapturing {
    public let events: AsyncStream<VoiceCaptureEvent>
    private let continuation: AsyncStream<VoiceCaptureEvent>.Continuation
    private let audio: VoiceAudioEngine
    private let locale: Locale
    private let core = CaptureCore()
    private var listener: SpeechListener?
    private var pump: Task<Void, Never>?

    /// Whether this device can run voice mode at all.
    public static var isSupported: Bool { SpeechTranscriber.isAvailable }

    public init(audio: VoiceAudioEngine, locale: Locale = Locale(identifier: "en-GB")) {
        self.audio = audio
        self.locale = locale
        (events, continuation) = AsyncStream.makeStream(of: VoiceCaptureEvent.self)
    }

    public func start(_ mode: VoiceModeEngine.CaptureMode) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw VoiceCaptureError.microphoneDenied }
        _ = await stop(keep: false)
        try audio.start()
        guard let format = audio.inputFormat, format.channelCount > 0 else { throw VoiceCaptureError.noInput }
        let listener = try await SpeechListener.make(locale: locale, inputFormat: format, recording: mode == .record)
        self.listener = listener
        core.begin(record: mode == .record, format: format)
        let core = self.core
        audio.input.set { buffer in
            core.append(buffer)
            listener.feed(buffer)
        }
        let continuation = self.continuation
        pump = Task {
            for await event in listener.events { continuation.yield(event) }
        }
    }

    public func promote() {
        core.promote()
        listener?.promote()
    }

    public func stop(keep: Bool) async -> URL? {
        audio.input.set(nil)
        let url = core.finish(keep: keep)
        pump?.cancel()
        pump = nil
        if let listener {
            self.listener = nil
            await listener.finish()
        }
        return url
    }
}

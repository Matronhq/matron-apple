import AVFoundation
import Foundation
import os

/// Hands the microphone tap's buffers to whoever is listening. The tap
/// runs on an audio thread; the consumer is swapped from the main actor.
final class InputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (AVAudioPCMBuffer) -> Void)?

    func set(_ handler: (@Sendable (AVAudioPCMBuffer) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func push(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(buffer)
    }
}

/// One `AVAudioEngine` for both directions (spec 2026-10-03 §3,
/// "Listening"): the microphone with Apple's voice processing switched on,
/// and the agent's clips played through the same engine, which is what
/// lets the echo canceller take the agent's voice back out of the
/// microphone so it can stay open while the agent speaks.
///
/// `setVoiceProcessingEnabled(_:)` may only be called while the engine is
/// stopped, and switching it on the input node switches the output node
/// too (AVFAudio `AVAudioIONode.h`;
/// https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)).
@MainActor
public final class VoiceAudioEngine: ClipOutput {
    private let engine = AVAudioEngine()
    private let voice = AVAudioPlayerNode()
    private let effects = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    let input = InputSink()
    private let voiceProcessing: Bool
    private var configured = false
    /// Bumped by every play and stop: a completion from a clip that was
    /// stopped or replaced is ignored.
    private var token = 0
    private var continuation: CheckedContinuation<Void, Error>?
    /// The microphone's format once the graph is built.
    public private(set) var inputFormat: AVAudioFormat?

    /// - Parameter voiceProcessing: `false` only for the spike's
    ///   comparison run.
    public init(voiceProcessing: Bool = true) {
        self.voiceProcessing = voiceProcessing
    }

    public var isRunning: Bool { engine.isRunning }

    /// The one format everything is played in. The graph is wired in it
    /// once, before the engine starts, and never rewired: connecting a
    /// node in a new format while the engine runs raises an exception on
    /// a phone (the first build did, at its first sound). A player node
    /// does not convert what is scheduled on it, so every clip, earcon
    /// and on-device line is converted to this format first.
    static let playFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    /// The playback half of the graph: the voice through the rate unit,
    /// and the earcons beside it. Its own function so a test can run the
    /// same wiring offline.
    static func wirePlayback(in engine: AVAudioEngine, voice: AVAudioPlayerNode, pitch: AVAudioUnitTimePitch,
                             effects: AVAudioPlayerNode) {
        engine.attach(voice)
        engine.attach(pitch)
        engine.attach(effects)
        engine.connect(voice, to: pitch, format: playFormat)
        engine.connect(pitch, to: engine.mainMixerNode, format: playFormat)
        engine.connect(effects, to: engine.mainMixerNode, format: playFormat)
    }

    private func configure() throws {
        guard !configured else { return }
        if voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        Self.wirePlayback(in: engine, voice: voice, pitch: pitch, effects: effects)
        let format = engine.inputNode.outputFormat(forBus: 0)
        inputFormat = format
        let sink = input
        engine.inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            sink.push(buffer)
        }
        configured = true
    }

    /// Starts the engine (building the graph first). The audio session
    /// must already be active.
    public func start() throws {
        try configure()
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    public func stopEngine() {
        stop()
        effects.stop()
        if engine.isRunning { engine.stop() }
    }

    // MARK: ClipOutput

    public func play(_ audio: Data, rate: Double) async throws {
        try await play(buffers: Self.pcm(of: Self.audioFile(audio)), rate: rate)
    }

    /// Plays PCM buffers end to end (the on-device voice renders a line
    /// as several), in whatever one format they share.
    func play(buffers: [AVAudioPCMBuffer], rate: Double) async throws {
        guard let buffer = Self.inPlayFormat(buffers) else { throw ClipOutputError.cannotPlay }
        stop()
        try start()
        token += 1
        let mine = token
        pitch.rate = Float(rate)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            voice.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                Task { @MainActor in self?.finished(mine) }
            }
            voice.play()
        }
    }

    private func finished(_ finishedToken: Int) {
        guard finishedToken == token else { return }
        continuation?.resume()
        continuation = nil
    }

    public func playEffect(_ audio: Data) {
        guard let file = try? Self.audioFile(audio), let pcm = try? Self.pcm(of: file),
              let buffer = Self.inPlayFormat(pcm), (try? start()) != nil else { return }
        effects.scheduleBuffer(buffer)
        effects.play()
    }

    public func stop() {
        token += 1
        voice.stop()
        continuation?.resume()
        continuation = nil
    }

    public func setVolume(_ volume: Float) {
        voice.volume = volume
    }

    /// Encoded bytes as a readable audio file. `AVAudioFile` reads from a
    /// URL only, so the bytes go through a temporary file, removed once it
    /// is open (the open handle keeps it readable).
    static func audioFile(_ audio: Data) throws -> AVAudioFile {
        let isWave = audio.prefix(4) == Data("RIFF".utf8)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString).\(isWave ? "wav" : "mp3")")
        try audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try AVAudioFile(forReading: url)
    }

    /// The whole of `file`, in the file's own PCM format, read a piece at
    /// a time up to its end. A read that fails throws: a clip that is cut
    /// short must not pass for one that played, or the on-device voice
    /// would never be asked to say the line instead. A clip is a line of
    /// speech or a short sound: seconds, not minutes.
    static func pcm(of file: AVAudioFile) throws -> [AVAudioPCMBuffer] {
        var pieces: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32_768) else {
                throw ClipOutputError.cannotPlay
            }
            try file.read(into: piece)
            guard piece.frameLength > 0 else { break }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else { throw ClipOutputError.cannotPlay }
        return pieces
    }

    /// `buffers`, end to end, as one buffer in `playFormat`: resampled,
    /// made mono and made float as needed. They must share a format (the
    /// first one's); any that does not is left out. `nil` when there is
    /// nothing to play or it cannot be converted.
    static func inPlayFormat(_ buffers: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let source = buffers.first?.format, source.sampleRate > 0 else { return nil }
        let usable = buffers.filter { $0.format == source && $0.frameLength > 0 }
        let frames = usable.reduce(0.0) { $0 + Double($1.frameLength) }
        guard frames > 0, let converter = AVAudioConverter(from: source, to: playFormat) else { return nil }
        let capacity = AVAudioFrameCount(frames * playFormat.sampleRate / source.sampleRate) + 4_096
        guard let out = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: capacity) else { return nil }
        var next = 0
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            guard next < usable.count else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            inputStatus.pointee = .haveData
            next += 1
            return usable[next - 1]
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

/// The buffers `AVSpeechSynthesizer.write` renders for one line, handed
/// over once: when the synthesizer ends the line, or when the line is
/// stopped first.
final class RenderedSpeech: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>?

    init(_ continuation: CheckedContinuation<[AVAudioPCMBuffer], Never>) {
        self.continuation = continuation
    }

    /// The synthesizer ends a line with an empty buffer.
    func take(_ buffer: AVAudioBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 {
            buffers.append(pcm)
        } else {
            continuation?.resume(returning: buffers)
            continuation = nil
        }
    }

    /// The line was stopped while it was still being rendered. Nothing
    /// says a stopped render still sends its closing empty buffer, and
    /// `speak` must return at once either way: it gets nothing to play.
    func abandon() {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: [])
        continuation = nil
    }
}

/// The on-device voice played through the capture engine, so it too is
/// echo-cancelled. `AVSpeechSynthesizer.write` renders the line to
/// buffers; the engine converts them to its play format and schedules them.
@MainActor
public final class EngineLocalVoice: LocalVoice {
    private let audio: VoiceAudioEngine
    private let synthesizer = AVSpeechSynthesizer()
    private var generation = 0
    /// The line being rendered, until the synthesizer has finished it.
    private var rendering: RenderedSpeech?

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-local")

    public init(audio: VoiceAudioEngine) {
        self.audio = audio
    }

    /// `false` when the line rendered to nothing or the engine would not
    /// play it: the caller must not report it as said.
    @discardableResult
    public func speak(_ text: String, rate: Double) async -> Bool {
        generation += 1
        let mine = generation
        rendering?.abandon()
        let utterance = SynthesizerLocalVoice.utterance(text, rate: rate, volume: 1)
        let rendered: [AVAudioPCMBuffer] = await withCheckedContinuation { continuation in
            let collector = RenderedSpeech(continuation)
            rendering = collector
            synthesizer.write(utterance) { collector.take($0) }
        }
        guard mine == generation else { return false }
        rendering = nil
        guard !rendered.isEmpty else {
            Self.logger.error("on-device voice rendered nothing")
            return false
        }
        do {
            try await audio.play(buffers: rendered, rate: 1)
            return true
        } catch {
            Self.logger.error("on-device voice would not play: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    public func stop() {
        generation += 1
        rendering?.abandon()
        rendering = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audio.stop()
    }

    public func setVolume(_ volume: Float) {
        audio.setVolume(volume)
    }

}

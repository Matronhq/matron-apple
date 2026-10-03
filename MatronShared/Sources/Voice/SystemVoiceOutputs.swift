import AVFoundation
import Foundation

public enum ClipOutputError: Error, Equatable, Sendable { case cannotPlay }

/// Plays clips with `AVAudioPlayer`. Enough to judge the voice (the PR 2
/// debug action); voice mode itself plays through `VoiceAudioEngine`.
@MainActor
public final class PlayerClipOutput: NSObject, ClipOutput, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var effects: [AVAudioPlayer] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var volume: Float = 1

    public override init() {}

    public func play(_ audio: Data, rate: Double) async throws {
        stop()
        let player = try AVAudioPlayer(data: audio)
        player.delegate = self
        player.enableRate = true
        player.rate = Float(rate)
        player.volume = volume
        self.player = player
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            if !player.play() {
                self.continuation = nil
                self.player = nil
                continuation.resume(throwing: ClipOutputError.cannotPlay)
            }
        }
    }

    public func playEffect(_ audio: Data) {
        guard let player = try? AVAudioPlayer(data: audio) else { return }
        effects.removeAll { !$0.isPlaying }
        effects.append(player)
        player.play()
    }

    public func stop() {
        player?.stop()
        player = nil
        continuation?.resume()
        continuation = nil
    }

    public func setVolume(_ volume: Float) {
        self.volume = volume
        player?.volume = volume
    }

    private func finished(_ finishedPlayer: AVAudioPlayer, error: Error?) {
        guard finishedPlayer === player else { return }
        player = nil
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finished(player, error: flag ? nil : ClipOutputError.cannotPlay) }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finished(player, error: error ?? ClipOutputError.cannotPlay) }
    }
}

/// The on-device voice, straight to the speaker.
@MainActor
public final class SynthesizerLocalVoice: NSObject, LocalVoice, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    /// The utterance `continuation` is waiting on. The synthesizer reports
    /// a stopped utterance's cancellation a moment after `stop()`, by
    /// which time the next line may already be waiting: only the current
    /// utterance's ending ends the wait.
    private var current: AVSpeechUtterance?
    private var volume: Float = 1

    public override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The utterance both on-device paths build: a British voice, at the
    /// user's rate.
    public static func utterance(_ text: String, rate: Double, volume: Float) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = min(max(AVSpeechUtteranceDefaultSpeechRate * Float(rate), AVSpeechUtteranceMinimumSpeechRate),
                             AVSpeechUtteranceMaximumSpeechRate)
        utterance.volume = volume
        return utterance
    }

    public func speak(_ text: String, rate: Double) async {
        stop()
        let utterance = Self.utterance(text, rate: rate, volume: volume)
        current = utterance
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
            synthesizer.speak(utterance)
        }
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        current = nil
        continuation?.resume()
        continuation = nil
    }

    /// Takes effect from the next line: an utterance's volume is fixed
    /// once it starts.
    public func setVolume(_ volume: Float) {
        self.volume = volume
    }

    private func finished(_ utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        continuation?.resume()
        continuation = nil
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }

    public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished(utterance) }
    }
}

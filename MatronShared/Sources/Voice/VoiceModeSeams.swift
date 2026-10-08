import Foundation

// The engine's edges (spec 2026-10-03 §3: "the audio, network and clock
// behind protocols"). A device supplies the real ones; tests supply fakes.

/// What the microphone side reports to the engine.
public enum VoiceCaptureEvent: Equatable, Sendable {
    case speechStarted
    case speechEnded
    /// The recogniser's words for the utterance so far.
    case words(String)
    case failed
}

/// The microphone: capture to a voice-note file, with the on-device
/// recogniser running alongside (`VoiceCapture` on a device).
@MainActor
public protocol VoiceCapturing: AnyObject {
    var events: AsyncStream<VoiceCaptureEvent> { get }
    func start(_ mode: VoiceModeEngine.CaptureMode) async throws
    /// Monitor becomes record, keeping the rolling half second.
    func promote()
    /// Closes the microphone. `keep`: the recorded file, when there is one.
    func stop(keep: Bool) async -> URL?
}

/// The audio session and engine: held only while listening or speaking.
@MainActor
public protocol VoiceAudioControlling: AnyObject {
    var events: AsyncStream<VoiceModeEngine.Event> { get }
    /// The current output route's name, e.g. "Speaker".
    var routeName: String { get }
    func activate() throws
    func release()
}

/// The voice (`SpeechPlayer`).
@MainActor
public protocol SpeechPlaying: AnyObject {
    @discardableResult func speak(_ text: String) async -> SpeechPlayer.Source
    func stop()
    func setDucked(_ ducked: Bool)
    func play(_ earcon: VoiceModeEngine.Earcon)
}

extension SpeechPlayer: SpeechPlaying {}

/// The network side (`JournalVoiceSender`).
public protocol VoiceSending: Sendable {
    /// `POST /media`; returns the blob ref.
    func upload(_ audio: Data) async throws -> String
    /// The journal's words for an uploaded note, or `nil`.
    func transcript(blobRef: String, waitSeconds: Int) async -> String?
    func sendVoiceNote(blobRef: String, size: Int, to target: VoiceModeEngine.SendTarget) async throws
    func sendItemAction(itemID: String, label: String) async
    func sendPromptReply(convoID: String, seq: Int64, choice: String?, text: String?) async throws
}

/// What happens in the conversations voice mode cares about
/// (`JournalVoiceFeed`).
@MainActor
public protocol VoiceFeeding: AnyObject {
    var events: AsyncStream<VoiceModeEngine.Event> { get }
    func watch(convoID: String)
    func stop()
}

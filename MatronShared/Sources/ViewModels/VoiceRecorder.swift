import Foundation
import AVFoundation

/// Records a short voice note to a temporary AAC `.m4a` file for sending as
/// an `audio/*` attachment. Works on both iOS and macOS (the base
/// deployment targets — iOS 17 / macOS 14 — both ship
/// `AVAudioApplication.requestRecordPermission()` and `AVAudioRecorder`).
///
/// The `AVAudioRecorder` is reached through the `AudioRecording` seam and
/// the permission prompt through an injectable closure so the state machine
/// (idle → recording → finished / cancel, no double-start) is unit-testable
/// without touching the microphone or the (device-only) permission dialog.
@MainActor
@Observable
public final class VoiceRecorder {
    public enum State: Equatable {
        case idle
        /// Actively capturing; `start` is the instant recording began, which
        /// the composer UI ticks against to show elapsed time.
        case recording(start: Date)
        case finished
    }

    public enum RecorderError: Error, Equatable {
        case permissionDenied
        case alreadyRecording
        case recordFailed
    }

    public private(set) var state: State = .idle

    private let requestPermission: () async -> Bool
    private let makeRecorder: (URL) throws -> AudioRecording
    private var recorder: AudioRecording?
    private var fileURL: URL?
    private var startedAt: Date?

    /// Injectable seam used by `VoiceRecorderTests` to drive the state
    /// machine with a fake recorder and a granted-permission stub. The
    /// public `init()` wires the real AVFoundation implementations.
    init(requestPermission: @escaping () async -> Bool,
         makeRecorder: @escaping (URL) throws -> AudioRecording) {
        self.requestPermission = requestPermission
        self.makeRecorder = makeRecorder
    }

    public convenience init() {
        self.init(requestPermission: VoiceRecorder.requestSystemPermission,
                  makeRecorder: VoiceRecorder.makeSystemRecorder)
    }

    /// Requests microphone permission (once), then starts recording to a
    /// fresh temp `.m4a`. Throws `.alreadyRecording` if a recording is in
    /// progress, `.permissionDenied` if the user declines, `.recordFailed`
    /// if `AVAudioRecorder` won't start.
    public func start() async throws {
        guard case .idle = state else { throw RecorderError.alreadyRecording }
        guard await requestPermission() else { throw RecorderError.permissionDenied }
        #if os(iOS)
        // macOS has no AVAudioSession; on iOS the session must be put into a
        // record category and activated before AVAudioRecorder will capture.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        let recorder = try makeRecorder(url)
        guard recorder.record() else { throw RecorderError.recordFailed }
        self.recorder = recorder
        self.fileURL = url
        let started = Date()
        self.startedAt = started
        state = .recording(start: started)
    }

    /// Stops recording and hands back the finished file plus its elapsed
    /// duration. Returns `nil` (a no-op) when not currently recording.
    public func stop() -> (url: URL, duration: TimeInterval)? {
        guard case .recording = state, let recorder, let fileURL, let startedAt else { return nil }
        recorder.stop()
        let duration = Date().timeIntervalSince(startedAt)
        self.recorder = nil
        self.fileURL = nil
        self.startedAt = nil
        state = .finished
        deactivateSession()
        return (fileURL, duration)
    }

    /// Aborts recording, discards the temp file, and returns to `.idle`.
    public func cancel() {
        recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
        startedAt = nil
        state = .idle
        deactivateSession()
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: Real AVFoundation implementations

    private static func requestSystemPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private static func makeSystemRecorder(url: URL) throws -> AudioRecording {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        return try AVAudioRecorder(url: url, settings: settings)
    }
}

/// The slice of `AVAudioRecorder` `VoiceRecorder` drives. Abstracted so the
/// state machine can be tested against a fake without capturing audio.
protocol AudioRecording: AnyObject {
    @discardableResult func record() -> Bool
    func stop()
}

extension AVAudioRecorder: AudioRecording {}

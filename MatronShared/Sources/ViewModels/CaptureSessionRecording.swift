#if os(macOS)
import AVFoundation
import MatronModels
import os

/// The Mac's voice-note recorder: a capture session writing AAC to the
/// note's `.m4a`. `AVAudioRecorder` can only record from the system's
/// default input; this records from the device the user picked, and can
/// move to another one mid-note without breaking the file.
///
/// Session work (starting it can take seconds while a Bluetooth headset
/// switches into its call profile) runs on a private queue, so `record()`
/// returns at once and the main thread never waits on the hardware;
/// `VoiceRecorder` polls `isCapturingAudio` until sound arrives.
final class CaptureSessionRecording: NSObject, AudioRecording, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private static let logger = os.Logger(subsystem: "chat.matron", category: "voice-recorder")
    /// Digital silence, as for `AVAudioRecorder.liveFloor`.
    static let liveFloor: Float = -120

    private let url: URL
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioFileOutput()
    private let queue = DispatchQueue(label: "chat.matron.voice-capture")
    private let finished = DispatchSemaphore(value: 0)

    /// Guarded by `lock`: read from the main actor while the queue writes.
    private let lock = NSLock()
    private var _microphone: Microphone?
    private var _recordingStarted = false
    private var _failed = false
    private var _stopRequested = false
    /// Main-actor side only.
    private var started = false

    init(url: URL) {
        self.url = url
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    }

    /// Every audio input the Mac has: built-in, USB, Bluetooth, virtual.
    static func microphones() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                         mediaType: .audio, position: .unspecified)
            .devices
            .map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    var microphone: Microphone? { locked { _microphone } }
    var hasFailed: Bool { locked { _failed } }

    var isCapturingAudio: Bool {
        guard locked({ _recordingStarted }), output.recordedDuration.seconds > 0 else { return false }
        let level = output.connection(with: .audio)?.audioChannels.map(\.peakHoldLevel).max() ?? -160
        return level > Self.liveFloor
    }

    func useMicrophone(_ id: String?) {
        queue.async { [self] in attach(id) }
    }

    func record() -> Bool {
        guard !started else { return true }
        started = true
        queue.async { [self] in
            if session.inputs.isEmpty { attach(nil) }
            guard !session.inputs.isEmpty, session.outputs.contains(output) else {
                Self.logger.error("capture: no input or output to record with")
                locked { _failed = true }
                return
            }
            session.startRunning()
            guard !locked({ _stopRequested }) else { return }
            output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        }
        return true
    }

    /// Finishes the file before returning: the caller reads it next. The
    /// wait is bounded so a capture that never started can't hang Stop.
    func stop() {
        guard started else { return }
        started = false
        locked { _stopRequested = true }
        let wasRecording = queue.sync { () -> Bool in
            let recording = output.isRecording
            if recording { output.stopRecording() }
            return recording
        }
        if wasRecording, finished.wait(timeout: .now() + 3) == .timedOut {
            Self.logger.error("capture: the file didn't finish within 3 s")
        }
        queue.async { [session] in session.stopRunning() }
    }

    /// Records from `id`, or the system's default input when it is nil or
    /// no longer connected. Runs on `queue`.
    private func attach(_ id: String?) {
        let device = id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else {
            Self.logger.error("capture: no audio input device")
            return
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            Self.logger.error("capture: can't open \(device.localizedName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        session.beginConfiguration()
        let previous = session.inputs
        previous.forEach(session.removeInput)
        if session.canAddInput(input) {
            session.addInput(input)
            locked { _microphone = Microphone(id: device.uniqueID, name: device.localizedName) }
        } else {
            // Keep recording from what we had rather than from nothing.
            previous.forEach { if session.canAddInput($0) { session.addInput($0) } }
            Self.logger.error("capture: can't record from \(device.localizedName, privacy: .public)")
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        locked { _recordingStarted = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        if let error {
            Self.logger.error("capture: finished with \(error.localizedDescription, privacy: .public)")
        }
        finished.signal()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif

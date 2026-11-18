import Foundation

/// Whether a capture's clock keeps pace with real time. A capture session
/// started while the Mac's audio devices are changing (a Bluetooth headset
/// connecting) can come up counting about a thousandth of the time that
/// passes: its clock still creeps forward, so it never looks stopped, but
/// almost nothing reaches the file. Fed the recorded duration as it is
/// polled, this compares each window of at least `window` seconds with the
/// real time it took.
struct CapturePace {
    /// The shortest stretch of real time judged.
    static let window: TimeInterval = 1
    /// A clock advancing by less than this share of real time is slow.
    static let slowShare = 0.25

    private var mark: (at: TimeInterval, recorded: TimeInterval)
    private(set) var isSlow = false

    /// `start`: when the capture began writing, on the clock `at` uses.
    init(start: TimeInterval) {
        mark = (start, 0)
    }

    /// Takes a reading and says whether the last whole window ran slow.
    mutating func check(at now: TimeInterval, recorded: TimeInterval) -> Bool {
        let passed = now - mark.at
        guard passed >= Self.window else { return isSlow }
        isSlow = recorded - mark.recorded < passed * Self.slowShare
        mark = (now, recorded)
        return isSlow
    }
}

#if os(macOS)
import AVFoundation
import MatronModels
import os

/// The Mac's voice-note recorder: a capture session writing AAC to the
/// note's `.m4a`. `AVAudioRecorder` can only record from the system's
/// default input; this records from the device the user picked. It
/// doesn't move devices itself: a pick while recording hands the note over
/// to a new recorder on the new device (`VoiceRecorder.selectMicrophone`).
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
    /// Set by the delegate's finish, which AVFoundation delivers on the
    /// main thread: `finished()` awaits it rather than blocking.
    private let fileFinished = RecordingFinishSignal()

    /// Guarded by `lock`: read from the main actor while the queue writes.
    private let lock = NSLock()
    private var _microphone: Microphone?
    private var _recordingStarted = false
    private var _failed = false
    private var _stopRequested = false
    /// `startRecording` was issued, so the output will report a finish
    /// (even for a start that fails). Set on the queue, before the
    /// main-thread `didStartRecordingTo` arrives.
    private var _recordingIssued = false
    /// Recording had been issued when `stop()` was called: a finish is owed.
    private var _finishOwed = false
    /// Set when the output starts writing; see `isRunningSlow`.
    private var _pace: CapturePace?
    /// Main-actor side only.
    private var started = false
    private var deviceID: String?

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

    /// Sound counts as arriving only once the file holds this much: a
    /// clock running slow (see `CapturePace`) is past zero at once but
    /// takes over a minute to get here.
    static let liveDuration: TimeInterval = 0.05

    var isCapturingAudio: Bool {
        guard locked({ _recordingStarted }), output.recordedDuration.seconds >= Self.liveDuration,
              !isRunningSlow else { return false }
        let level = output.connection(with: .audio)?.audioChannels.map(\.peakHoldLevel).max() ?? -160
        return level > Self.liveFloor
    }

    var canSwitchMicrophoneLive: Bool { false }

    var isRunningSlow: Bool {
        let recorded = elapsed
        let now = ProcessInfo.processInfo.systemUptime
        return locked {
            guard !_stopRequested, !_failed else { return false }
            return _pace?.check(at: now, recorded: recorded) ?? false
        }
    }

    var elapsed: TimeInterval {
        let seconds = output.recordedDuration.seconds
        return seconds.isFinite ? seconds : 0
    }

    /// Chooses the device before `record()`. The name is known at once,
    /// so the bar can show it while the hardware is still starting.
    func useMicrophone(_ id: String?) {
        deviceID = id
        let device = Self.device(for: id)
        locked { _microphone = device.map { Microphone(id: $0.uniqueID, name: $0.localizedName) } }
    }

    private static func device(for id: String?) -> AVCaptureDevice? {
        id.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
    }

    func record() -> Bool {
        guard !started else { return true }
        started = true
        let id = deviceID
        queue.async { [self] in
            attach(id)
            guard !session.inputs.isEmpty, session.outputs.contains(output) else {
                Self.logger.error("capture: no input or output to record with")
                locked { _failed = true }
                return
            }
            session.startRunning()
            let proceed = locked { () -> Bool in
                guard !_stopRequested else { return false }
                _recordingIssued = true
                return true
            }
            guard proceed else { return }
            output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
        }
        return true
    }

    /// Asks the output to finish the file and returns at once; `finished()`
    /// says when it has. Never waits here: AVFoundation reports the finish
    /// on the main thread, which is the thread calling this, and the
    /// queue may be inside a slow `startRunning()` (Cancel while a headset
    /// comes up). A start still in flight sees the stop request and goes
    /// no further.
    func stop() {
        guard started else { return }
        started = false
        locked {
            _stopRequested = true
            _finishOwed = _recordingIssued
        }
        // The session keeps running until the file is finished (the
        // delegate stops it), so the output's last audio reaches the file.
        queue.async { [self] in
            if output.isRecording {
                output.stopRecording()
            } else {
                session.stopRunning()
            }
        }
    }

    /// Returns once the file `stop()` asked for is complete, or after 3 s
    /// if the output never says so.
    func finished() async {
        guard locked({ _finishOwed }) else { return }
        if await !fileFinished.wait(timeout: 3) {
            Self.logger.error("capture: the file didn't finish within 3 s")
            // Unconfirmed: the note is held for the user, not sent as whole.
            locked { _failed = true }
            // The delegate that would have stopped the session never came.
            queue.async { [session] in session.stopRunning() }
        }
    }

    /// Records from `id`, or the system's default input when it is nil or
    /// no longer connected. Runs on `queue`, before the session starts.
    private func attach(_ id: String?) {
        guard let device = Self.device(for: id) else {
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
        if session.canAddInput(input) {
            session.addInput(input)
            locked { _microphone = Microphone(id: device.uniqueID, name: device.localizedName) }
        } else {
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
        let now = ProcessInfo.processInfo.systemUptime
        locked {
            _recordingStarted = true
            _pace = CapturePace(start: now)
        }
        Self.logger.notice("capture: started writing")
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let unexpected = locked { () -> Bool in
            // A finish nobody asked for: the start failed, or the device
            // went away. The warm-up gives up on it; a recording already
            // live keeps what reached the file, which Stop then sends.
            if !_stopRequested { _failed = true }
            return !_stopRequested
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int) ?? -1
        let seconds = output.recordedDuration.seconds
        if let error {
            Self.logger.error("capture: finished with \(error.localizedDescription, privacy: .public) unexpected=\(unexpected) recorded=\(seconds, format: .fixed(precision: 2))s bytes=\(bytes)")
        } else if unexpected {
            Self.logger.error("capture: stopped on its own recorded=\(seconds, format: .fixed(precision: 2))s bytes=\(bytes)")
        } else {
            Self.logger.notice("capture: finished recorded=\(seconds, format: .fixed(precision: 2))s bytes=\(bytes)")
        }
        if !unexpected { queue.async { [session] in session.stopRunning() } }
        fileFinished.signal()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
#endif

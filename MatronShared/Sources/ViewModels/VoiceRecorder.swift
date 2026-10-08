import Foundation
import AVFoundation
import os
#if os(iOS)
import UIKit
#endif

/// An audio-session interruption as the recorder sees it: a phone call,
/// Siri, or another app taking the microphone. iOS pauses the
/// `AVAudioRecorder` on `began`; `ended` says whether the system wants us
/// back on the mic (`shouldResume`). Platform-neutral so the resume logic
/// is testable where `AVAudioSession` doesn't exist (macOS, the shared
/// package's test host).
public enum AudioInterruption: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

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

    /// Breadcrumbs for the "note came back silent" class of report
    /// (2026-09-06: three notes in a row carried no voice at all while the
    /// mic still heard taps on the phone body — the input route at the
    /// time was the unanswerable question). Read on-device with Console or
    /// `log collect --device`, subsystem chat.matron.
    private static let logger = os.Logger(subsystem: "chat.matron", category: "voice-recorder")

    private let requestPermission: () async -> Bool
    private let makeRecorder: (URL) throws -> AudioRecording
    /// `true` while capture is live, `false` once it ends — keeps the screen
    /// from auto-locking mid-recording (locking suspends the app and kills
    /// the capture). Injectable so tests can observe the claim/release pair.
    private let setKeepScreenAwake: (Bool) -> Void
    /// Subscribes a handler to interruption events for the life of one
    /// recording and returns the unsubscribe. Injectable so tests can
    /// deliver events; the real source maps `AVAudioSession`'s notification.
    private let observeInterruptions: (@escaping @MainActor (AudioInterruption) -> Void) -> () -> Void
    private var stopObservingInterruptions: (() -> Void)?
    /// True between an interruption's `began` and its `ended` — the only
    /// window in which an `ended` may resume capture. An `ended` with no
    /// `began` is a stale notification, not a reason to poke the recorder.
    private var isInterrupted = false
    /// Interruption bookkeeping for the reported duration: capture time,
    /// not wall time — a call in the middle of a note is silence the
    /// recorder never captured. `pausedSince` is set on `began` and cleared
    /// only by a resume; an unresumed pause runs until `stop()`.
    private var pausedSince: Date?
    private var pausedTotal: TimeInterval = 0
    private let now: () -> Date
    private var recorder: AudioRecording?
    private var fileURL: URL?
    private var startedAt: Date?
    /// True from `start()`'s entry until it settles — rejects a second tap
    /// racing the permission `await` (state is still `.idle` in that gap, so
    /// the state check alone can't).
    private var isStarting = false
    /// Bumped by `cancel()`. `start()` snapshots it before the permission
    /// `await` and aborts quietly if it moved — a cancel that lands while
    /// the permission dialog is up (composer disappeared, second view
    /// teardown) must win over the in-flight start, or capture would begin
    /// with no recording UI. Everything after the single `await` is
    /// synchronous on the main actor, so one check suffices.
    private var cancelGeneration = 0

    /// Injectable seam used by `VoiceRecorderTests` to drive the state
    /// machine with a fake recorder and a granted-permission stub. The
    /// public `init()` wires the real AVFoundation implementations.
    init(requestPermission: @escaping () async -> Bool,
         makeRecorder: @escaping (URL) throws -> AudioRecording,
         setKeepScreenAwake: @escaping (Bool) -> Void = { _ in },
         observeInterruptions: @escaping (@escaping @MainActor (AudioInterruption) -> Void) -> () -> Void = { _ in {} },
         now: @escaping () -> Date = Date.init) {
        self.requestPermission = requestPermission
        self.makeRecorder = makeRecorder
        self.setKeepScreenAwake = setKeepScreenAwake
        self.observeInterruptions = observeInterruptions
        self.now = now
    }

    public convenience init() {
        self.init(requestPermission: VoiceRecorder.requestSystemPermission,
                  makeRecorder: VoiceRecorder.makeSystemRecorder,
                  setKeepScreenAwake: VoiceRecorder.setSystemKeepScreenAwake,
                  observeInterruptions: VoiceRecorder.observeSystemInterruptions)
    }

    /// Requests microphone permission (once), then starts recording to a
    /// fresh temp `.m4a`. Throws `.alreadyRecording` if a recording is in
    /// progress, `.permissionDenied` if the user declines, `.recordFailed`
    /// if `AVAudioRecorder` won't start.
    public func start() async throws {
        // Reject only an in-flight recording or start; a fresh start from
        // `.idle` or a prior `.finished` (a second voice note) is allowed.
        if case .recording = state { throw RecorderError.alreadyRecording }
        guard !isStarting else { throw RecorderError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        let generation = cancelGeneration
        guard await requestPermission() else { throw RecorderError.permissionDenied }
        // A cancel() landed while the permission prompt was up — the start
        // is abandoned before any session/recorder work. Quiet no-op: the
        // user asked for silence, not an error.
        guard generation == cancelGeneration else { return }
        #if os(iOS)
        // macOS has no AVAudioSession; on iOS the session must be put into a
        // record category and activated before AVAudioRecorder will capture.
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        Self.logSessionState(session, at: "start")
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-note-\(UUID().uuidString).m4a")
        do {
            let recorder = try makeRecorder(url)
            guard recorder.record() else { throw RecorderError.recordFailed }
            self.recorder = recorder
            self.fileURL = url
            let started = now()
            self.startedAt = started
            state = .recording(start: started)
            setKeepScreenAwake(true)
            isInterrupted = false
            pausedSince = nil
            pausedTotal = 0
            stopObservingInterruptions = observeInterruptions { [weak self] event in
                self?.handle(interruption: event)
            }
        } catch {
            // The session was already activated above — a failed recorder
            // construction or start must not leave it captured, nor leave an
            // orphan temp file behind.
            deactivateSession()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Stops recording and hands back the finished file plus its elapsed
    /// duration. Returns `nil` (a no-op) when not currently recording.
    public func stop() -> (url: URL, duration: TimeInterval)? {
        guard case .recording = state, let recorder, let fileURL, let startedAt else { return nil }
        recorder.stop()
        let stoppedAt = now()
        let stillPaused = pausedSince.map { stoppedAt.timeIntervalSince($0) } ?? 0
        let duration = stoppedAt.timeIntervalSince(startedAt) - pausedTotal - stillPaused
        let bytes = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? -1
        Self.logger.info("stop: duration=\(duration, format: .fixed(precision: 2))s paused=\(self.pausedTotal + stillPaused, format: .fixed(precision: 2))s bytes=\(bytes)")
        #if os(iOS)
        Self.logSessionState(AVAudioSession.sharedInstance(), at: "stop")
        #endif
        self.recorder = nil
        self.fileURL = nil
        self.startedAt = nil
        state = .finished
        setKeepScreenAwake(false)
        unsubscribeInterruptions()
        deactivateSession()
        return (fileURL, duration)
    }

    /// Aborts recording, discards the temp file, and returns to `.idle`.
    /// Also invalidates any start() suspended at its permission prompt.
    public func cancel() {
        cancelGeneration &+= 1
        recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        recorder = nil
        fileURL = nil
        startedAt = nil
        state = .idle
        setKeepScreenAwake(false)
        unsubscribeInterruptions()
        deactivateSession()
    }

    /// iOS has already paused the recorder on `began`; on `ended` with the
    /// resume hint, re-activating the session and calling `record()` picks
    /// capture up in the same file. Without the hint the system doesn't
    /// want us back on the mic (another app took it): the recorder stays
    /// paused, and a later `stop()` still delivers what was captured. A
    /// failed resume is left alone for the same reason.
    private func handle(interruption: AudioInterruption) {
        Self.logger.info("interruption: \(String(describing: interruption), privacy: .public) state=\(String(describing: self.state), privacy: .public) wasInterrupted=\(self.isInterrupted)")
        guard case .recording = state, let recorder else { return }
        switch interruption {
        case .began:
            isInterrupted = true
            if pausedSince == nil { pausedSince = now() }
        case .ended(let shouldResume):
            guard isInterrupted else { return }
            isInterrupted = false
            guard shouldResume else { return }
            reactivateSession()
            // A failed resume leaves the recorder paused: the pause keeps
            // running until stop(), so it stays open here too.
            guard recorder.record() else { return }
            if let pausedSince {
                pausedTotal += now().timeIntervalSince(pausedSince)
                self.pausedSince = nil
            }
        }
    }

    private func unsubscribeInterruptions() {
        stopObservingInterruptions?()
        stopObservingInterruptions = nil
        isInterrupted = false
        pausedSince = nil
        pausedTotal = 0
    }

    private func reactivateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(true)
        } catch {
            Self.logger.error("resume: setActive failed: \(error.localizedDescription, privacy: .public)")
        }
        Self.logSessionState(session, at: "resume")
        #endif
    }

    #if os(iOS)
    /// One line per recording milestone with everything that decides what
    /// the file will contain: the input route iOS actually chose (a
    /// connected accessory can override the built-in mic), input
    /// availability and gain, and the permission state. Strings are marked
    /// public on purpose: os.Logger redacts interpolated strings as
    /// `<private>` on a real device, which would hide the very route names
    /// this line exists to show. Port types and names are not sensitive.
    private static func logSessionState(_ session: AVAudioSession, at milestone: String) {
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        logger.info("\(milestone, privacy: .public): inputs=[\(inputs, privacy: .public)] outputs=[\(outputs, privacy: .public)] inputAvailable=\(session.isInputAvailable) gain=\(session.inputGain, format: .fixed(precision: 2)) channels=\(session.inputNumberOfChannels) sampleRate=\(session.sampleRate, format: .fixed(precision: 0)) permission=\(AVAudioApplication.shared.recordPermission.rawValue) otherAudio=\(session.isOtherAudioPlaying)")
    }
    #endif

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    // MARK: Real AVFoundation implementations

    private static func requestSystemPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    /// While recording, the device must not auto-lock: locking suspends the
    /// app mid-capture and the note is cut short. macOS has no idle-lock
    /// equivalent that interrupts capture, so this is iOS-only.
    private static func setSystemKeepScreenAwake(_ keepAwake: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
        #endif
    }

    /// Maps `AVAudioSession.interruptionNotification` onto
    /// `AudioInterruption`, delivered on the main actor. macOS has no
    /// audio session and no interruptions of this kind: no-op there.
    private static func observeSystemInterruptions(
        _ handler: @escaping @MainActor (AudioInterruption) -> Void
    ) -> () -> Void {
        #if os(iOS)
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let event: AudioInterruption
            switch type {
            case .began:
                event = .began
            case .ended:
                let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                event = .ended(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return
            }
            MainActor.assumeIsolated { handler(event) }
        }
        return { NotificationCenter.default.removeObserver(token) }
        #else
        return {}
        #endif
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

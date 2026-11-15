import AVFoundation
import Foundation
import os

/// Voice mode's hold on the device's audio (spec 2026-10-03 §3, "Audio
/// session"): `.playAndRecord` with voice processing, active only while
/// the engine is listening or speaking, and given back (telling other apps)
/// when it waits, so music or the radio returns. A call or Siri pauses the
/// engine, as `VoiceRecorder` does for a voice note.
@MainActor
public final class VoiceAudioSession: VoiceAudioControlling {
    public let events: AsyncStream<VoiceModeEngine.Event>
    private let continuation: AsyncStream<VoiceModeEngine.Event>.Continuation
    private let engine: VoiceAudioEngine
    private var observers: [NSObjectProtocol] = []
    private var active = false

    private static let logger = Logger(subsystem: "chat.matron", category: "voice-session")

    public init(engine: VoiceAudioEngine) {
        self.engine = engine
        (events, continuation) = AsyncStream.makeStream(of: VoiceModeEngine.Event.self)
        observe()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    public var routeName: String {
        #if os(iOS)
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.isEmpty ? "none" : outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        #else
        return "Mac"
        #endif
    }

    public func activate() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // The loudspeaker, not the earpiece, when nothing else is
        // connected; AirPods and a car's hands-free when they are.
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        Self.logger.info("active: route=\(self.routeName, privacy: .public) sampleRate=\(session.sampleRate, format: .fixed(precision: 0))")
        #endif
        active = true
        try engine.start()
    }

    /// Gives the audio back. Does nothing to the session unless this
    /// object activated it: a session it never took may be someone
    /// else's (a voice note being recorded).
    public func release() {
        let held = active
        active = false
        engine.stopEngine()
        guard held else { return }
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private func observe() {
        let center = NotificationCenter.default
        // A route change (AirPods in or out) reconfigures the engine,
        // which stops it: start it again while voice mode holds the audio.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.active else { return }
                try? self.engine.start()
            }
        })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            MainActor.assumeIsolated {
                switch type {
                case .began: self?.continuation.yield(.interruption(.began))
                case .ended: self?.continuation.yield(.interruption(.ended(shouldResume: shouldResume)))
                @unknown default: break
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.continuation.yield(.routeChanged(self.routeName))
            }
        })
        #endif
    }
}

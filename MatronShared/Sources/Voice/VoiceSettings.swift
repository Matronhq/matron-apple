import Foundation
import Observation
import MatronJournal

/// Voice mode's settings (spec 2026-10-03 §6): which voice, how fast,
/// whether talking over the agent interrupts it, and whether "more" is
/// offered after a reply. Per device, in `UserDefaults`.
@MainActor
@Observable
public final class VoiceSettings {
    /// The voice id sent to `POST /tts`; `onDevice` never asks the journal.
    public static let onDevice = "on-device"
    /// The cloud voices offered before `GET /tts/voices` has answered.
    public static let builtInVoices = [TTSVoice(id: "en-GB-Harry", name: "Harry", gender: "male"),
                                       TTSVoice(id: "en-GB-Emily", name: "Emily", gender: "female")]
    public static let rateRange: ClosedRange<Double> = 0.8...1.5

    enum Key {
        static let voice = "matron.voice.voice"
        static let rate = "matron.voice.rate"
        static let talkOver = "matron.voice.talkOver"
        static let offerMore = "matron.voice.offerMore"
        static let debugTools = "matron.voice.debugTools"
    }

    private let defaults: UserDefaults

    /// `nil` = the journal's default voice.
    public var voice: String? { didSet { defaults.set(voice, forKey: Key.voice) } }
    public var rate: Double { didSet { defaults.set(rate, forKey: Key.rate) } }
    public var talkOver: Bool { didSet { defaults.set(talkOver, forKey: Key.talkOver) } }
    public var offerMore: Bool { didSet { defaults.set(offerMore, forKey: Key.offerMore) } }
    /// Shows "Speak a reply" in a conversation's Session sheet. Hidden:
    /// switched by a long press on the settings section's title, so the
    /// voice can be judged on a TestFlight build, where `MatronDebug` is off.
    public var debugTools: Bool { didSet { defaults.set(debugTools, forKey: Key.debugTools) } }

    /// - Parameter talkOverDefault: what "Talk over the agent" is before
    ///   the user touches it. `true` per the spec; the PR 3 spike's
    ///   fallback ships it `false`.
    public init(defaults: UserDefaults = .standard, talkOverDefault: Bool = true) {
        self.defaults = defaults
        voice = defaults.string(forKey: Key.voice)
        let stored = defaults.object(forKey: Key.rate) as? Double ?? 1
        rate = min(max(stored, Self.rateRange.lowerBound), Self.rateRange.upperBound)
        talkOver = defaults.object(forKey: Key.talkOver) as? Bool ?? talkOverDefault
        offerMore = defaults.object(forKey: Key.offerMore) as? Bool ?? true
        debugTools = defaults.bool(forKey: Key.debugTools)
    }

    public var usesOnDeviceVoice: Bool { voice == Self.onDevice }

    /// These settings as the engine reads them.
    public func engineConfig(_ base: VoiceModeEngine.Config = VoiceModeEngine.Config()) -> VoiceModeEngine.Config {
        var config = base
        config.talkOver = talkOver
        config.offerMore = offerMore
        return config
    }
}

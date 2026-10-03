import MatronDesignSystem
import MatronVoice

extension VoiceTextMaker {
    /// The app's Markdown cleaner, handed to the voice engine's feed (the
    /// engine's module never imports the renderers).
    static let cleaner = VoiceTextMaker(
        short: { SpeechCleaner.fallbackShort($0) },
        sections: { SpeechCleaner.sections($0) },
        plain: { SpeechCleaner.speakable($0) })
}

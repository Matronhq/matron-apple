import XCTest
import MatronJournal
import MatronVoice
@testable import Matron

/// Voice mode's settings section and the hidden "Speak a reply" list
/// (spec 2026-10-03 §6; plan PR 2).
@MainActor
final class VoiceSettingsTests: XCTestCase {
    func test_voicePickerSelection() {
        let voices = VoiceSettings.builtInVoices
        XCTAssertEqual(VoiceSettingsSection.selection(stored: nil, defaultVoiceID: "en-GB-Emily", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Emily", "the journal's default")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: nil, defaultVoiceID: nil, voices: voices,
                                                      cloudUnavailable: false), "en-GB-Harry", "else the first on offer")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "en-GB-Emily", defaultVoiceID: "en-GB-Harry", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Emily")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "gone", defaultVoiceID: "en-GB-Harry", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Harry", "a voice the journal dropped")
        XCTAssertEqual(VoiceSettingsSection.selection(stored: VoiceSettings.onDevice, defaultVoiceID: "en-GB-Harry",
                                                      voices: voices, cloudUnavailable: false), VoiceSettings.onDevice)
        XCTAssertEqual(VoiceSettingsSection.selection(stored: "en-GB-Emily", defaultVoiceID: nil, voices: voices,
                                                      cloudUnavailable: true), VoiceSettings.onDevice, "no cloud voice")
        XCTAssertEqual(VoiceSettingsSection.rateLabel(1.2), "1.2×")
    }
}

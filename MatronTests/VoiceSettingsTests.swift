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
        XCTAssertEqual(VoiceSettingsSection.selection(stored: nil, defaultVoiceID: "en-GB-New", voices: voices,
                                                      cloudUnavailable: false), "en-GB-Harry",
                       "a default the journal does not list has no row to show")
        XCTAssertEqual(VoiceSettingsSection.rateLabel(1.2), "1.2×")
        XCTAssertEqual(VoiceSettingsSection.stepped(0.8 + 0.1 * 4), 1.2)
    }

    func test_debugLinesAreTheCleanerLineThenEachTurnsSpokenLines() throws {
        let store = try JournalStore(databaseURL: nil, ownSender: "user:alice")
        func event(_ seq: Int64, type: String, _ payload: [String: Any]) -> JournalEvent {
            JournalEvent(seq: seq, convoID: "c1", ts: Date(timeIntervalSince1970: Double(seq)), sender: "agent:aspen", type: type,
                         payloadData: try! JSONSerialization.data(withJSONObject: payload))
        }
        _ = try store.applyJournalBatch([
            event(1, type: "text", ["body": "The deploy finished. All green. Nothing else.", "message_ref": "m1"]),
            event(2, type: "summary", ["toc": "Deploy", "spoken": "It is deployed.", "spoken_more": "Every test passed.", "spoken_ref": "m1"]),
            event(3, type: "summary", ["toc": "Old bridge"]),
        ])
        let lines = VoiceDebugView.lines(convoID: "c1", store: store)
        XCTAssertEqual(lines.map(\.text), ["The deploy finished. All green.", "It is deployed.", "Every test passed."])
        XCTAssertEqual(lines.map(\.title), ["Last reply, through the cleaner", "Deploy", "Deploy (more)"])
    }
}

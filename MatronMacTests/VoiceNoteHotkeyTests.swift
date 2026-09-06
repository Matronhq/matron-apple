#if os(macOS)
import XCTest
@testable import MatronMac

/// The pure half of the global voice-note hotkey: which Carbon key code a
/// preference maps to, what a press should do given the app's state, and
/// the command bus the composer listens on. The Carbon registration itself
/// is not driven here — it needs a live event loop and a real key.
@MainActor
final class VoiceNoteHotkeyTests: XCTestCase {
    func test_defaultKeyIsF5_withCarbonCode96() {
        XCTAssertEqual(VoiceNoteHotkeyKey.default, .f5)
        XCTAssertEqual(VoiceNoteHotkeyKey.f5.carbonKeyCode, 96)
        XCTAssertEqual(VoiceNoteHotkeyKey.f13.carbonKeyCode, 105)
    }

    func test_offHasNoKeyCode_andEveryOtherKeyDoes() {
        XCTAssertNil(VoiceNoteHotkeyKey.off.carbonKeyCode)
        for key in VoiceNoteHotkeyKey.allCases where key != .off {
            XCTAssertNotNil(key.carbonKeyCode, "\(key) must register")
        }
    }

    func test_storedRawValueRoundTrips() {
        for key in VoiceNoteHotkeyKey.allCases {
            XCTAssertEqual(VoiceNoteHotkeyKey(rawValue: key.rawValue), key)
        }
        XCTAssertEqual(VoiceNoteHotkeyKey.storageKey, "VoiceNoteHotkey")
    }

    func test_pressResolution_startsThenStopsAndSends_refusesWithoutAComposer() {
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: false, hasComposer: true), .start)
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: true, hasComposer: true), .stopAndSend)
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: false, hasComposer: false), .refuse)
        // A recording can't outlive its composer (it cancels on disappear),
        // but if the flags ever disagree, refusing is the safe answer.
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: true, hasComposer: false), .refuse)
    }

    func test_bus_countsPresses_andTracksRecording() {
        let bus = VoiceNoteCommandBus()
        XCTAssertEqual(bus.pressCount, 0)
        bus.press()
        bus.press()
        XCTAssertEqual(bus.pressCount, 2)
        XCTAssertNil(bus.recordingStart)
        let start = Date()
        bus.recordingStart = start
        XCTAssertEqual(bus.recordingStart, start)
    }
}
#endif

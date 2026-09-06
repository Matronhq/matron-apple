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

    /// The lock is an overlay — the composer stays mounted behind it — so
    /// the key must refuse on the lock itself, or a passer-by could record
    /// and send into the last chat (Bugbot + CodeRabbit, PR #182). Same
    /// for a build whose composer hides the mic (`mediaAvailable`).
    func test_pressResolution_refusesWhileLocked_orWithoutMedia() {
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: false, hasComposer: true, isLocked: true), .refuse)
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: true, hasComposer: true, isLocked: true), .refuse)
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: false, hasComposer: true, mediaAvailable: false), .refuse)
        XCTAssertEqual(VoiceNoteHotkeyAction.resolve(isRecording: false, hasComposer: true, isLocked: false, mediaAvailable: true), .start)
    }

    func test_bus_countsPresses_andTracksRecording() {
        let bus = VoiceNoteCommandBus()
        let composer = UUID()
        bus.claim(composer)
        XCTAssertEqual(bus.pressCount, 0)
        bus.press()
        bus.press()
        XCTAssertEqual(bus.pressCount, 2)
        XCTAssertNil(bus.recordingStart)
        let start = Date()
        bus.recordingStart = start
        XCTAssertEqual(bus.recordingStart, start)
    }

    /// A chat switch mounts the successor composer BEFORE the outgoing one
    /// disappears, so a single boolean written from both would end up
    /// false (Bugbot, PR #182). A release only clears its own claim.
    func test_bus_successorClaimSurvivesPredecessorRelease() {
        let bus = VoiceNoteCommandBus()
        let outgoing = UUID(), successor = UUID()
        bus.claim(outgoing)
        bus.claim(successor)
        bus.release(outgoing)
        XCTAssertEqual(bus.activeComposerID, successor)
        XCTAssertTrue(bus.hasActiveComposer)
        bus.release(successor)
        XCTAssertNil(bus.activeComposerID)
        XCTAssertFalse(bus.hasActiveComposer)
    }

    /// With File → New Window, several composers observe the same bus; a
    /// press must land in exactly one — the claimed (key-window) composer.
    func test_bus_pressTargetsTheActiveComposerOnly() {
        let bus = VoiceNoteCommandBus()
        let a = UUID(), b = UUID()
        bus.claim(a)
        bus.claim(b)
        bus.press()
        XCTAssertEqual(bus.pressTarget, b)
        bus.claim(a)
        bus.press()
        XCTAssertEqual(bus.pressTarget, a)
    }
}
#endif

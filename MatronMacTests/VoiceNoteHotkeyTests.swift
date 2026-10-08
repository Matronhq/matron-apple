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

    func test_bus_countsPresses_andAddressesTheActiveComposer() {
        let bus = VoiceNoteCommandBus()
        let a = UUID(), b = UUID()
        bus.claim(a)
        XCTAssertEqual(bus.pressCount, 0)
        bus.press()
        bus.press()
        XCTAssertEqual(bus.pressCount, 2)
        XCTAssertEqual(bus.pressTarget, a)
        bus.claim(b)
        bus.press()
        XCTAssertEqual(bus.pressTarget, b, "the key window's composer starts")
    }

    /// A press while a note records stops it at the root and
    /// sends it where it began — whatever page, window or composer is in
    /// front, or none at all. So switching windows or pages mid-note can
    /// never start a second capture (Bugbot round 2, PR #182) and a note
    /// begun in a chat the user has since left still ends on the key.
    func test_route_stopsALiveNoteFromAnywhere_andStartsOnlyInAComposer() {
        XCTAssertEqual(VoiceNoteHotkeyRoute.resolve(isRecording: true, hasComposer: true, isLocked: false), .stopAndSend)
        XCTAssertEqual(VoiceNoteHotkeyRoute.resolve(isRecording: true, hasComposer: false, isLocked: false), .stopAndSend,
                       "no chat on screen (Decisions, Projects): the live note still ends and sends")
        XCTAssertEqual(VoiceNoteHotkeyRoute.resolve(isRecording: false, hasComposer: true, isLocked: false), .startInComposer)
        XCTAssertEqual(VoiceNoteHotkeyRoute.resolve(isRecording: false, hasComposer: false, isLocked: false), .refuse)
        XCTAssertEqual(VoiceNoteHotkeyRoute.resolve(isRecording: true, hasComposer: true, isLocked: true), .refuse,
                       "the lock refuses even a stop: a passer-by must not send the note")
    }

    /// A composer that mounts in a window which is NOT key (a chat switch
    /// in a background window) must not steal the claim from the key
    /// window's composer; it may only take an unclaimed bus.
    func test_bus_claimIfKeyOrUnclaimed() {
        let bus = VoiceNoteCommandBus()
        let key = UUID(), background = UUID()
        bus.claim(key)
        bus.claimIfKey(background, isKey: false)
        XCTAssertEqual(bus.activeComposerID, key)
        bus.release(key)
        bus.claimIfKey(background, isKey: false)
        XCTAssertEqual(bus.activeComposerID, background, "an unclaimed bus takes any composer")
        bus.claimIfKey(key, isKey: true)
        XCTAssertEqual(bus.activeComposerID, key)
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

    /// Task 14 fix round 1: when the composer holding the bus goes away,
    /// the bus goes back to the one before it IN THAT WINDOW — not to
    /// nothing (the hotkey went dead) and never to a released composer or
    /// another window's.
    func test_bus_releaseHandsTheBusBackToThePreviousClaimantInThatWindow() {
        let bus = VoiceNoteCommandBus()
        let windowA = NSObject(), windowB = NSObject()
        let first = UUID(), second = UUID(), other = UUID()
        bus.claim(first, window: ObjectIdentifier(windowA))
        bus.claim(other, window: ObjectIdentifier(windowB))
        bus.claim(second, window: ObjectIdentifier(windowA))
        bus.release(second)
        XCTAssertEqual(bus.activeComposerID, first, "the window's remaining composer takes the bus back")
        bus.release(first)
        XCTAssertNil(bus.activeComposerID, "no composer left in window A: another window's does not inherit")
        bus.claim(second, window: ObjectIdentifier(windowA))
        bus.release(second)
        XCTAssertNil(bus.activeComposerID, "a released composer is never handed the bus again")
    }

    /// Bugbot (PR #234, VoiceNoteHotkey ~126): `WindowAccessor` can report a
    /// nil window first. A later non-nil window must refresh the entry —
    /// for the holder and for a claimant that does not take the bus — and
    /// never be overwritten by nil again; otherwise `release`'s same-window
    /// hand-back finds nobody.
    func test_bus_laterWindowRefreshesAnEntryFirstSeenWithoutOne() {
        let bus = VoiceNoteCommandBus()
        let objectA = NSObject()
        let windowA = ObjectIdentifier(objectA)
        let main = UUID(), second = UUID()
        bus.claimIfKey(main, isKey: false, window: nil)      // unclaimed bus: taken, window unknown
        bus.claimIfKey(second, isKey: false, window: nil)    // held: recorded as the oldest claimant
        bus.claimIfKey(main, isKey: false, window: windowA)  // not key: no claim, but the window is learnt
        bus.claimIfKey(second, isKey: false, window: windowA)
        bus.claimIfKey(main, isKey: false, window: nil)      // a stray nil never erases it
        XCTAssertEqual(bus.windowOf(main), windowA)
        XCTAssertEqual(bus.windowOf(second), windowA)
        bus.release(main)
        XCTAssertEqual(bus.activeComposerID, second)
        withExtendedLifetime(objectA) {}
    }

    /// #2852 remainder: an unknown (nil) window matches NO window. A
    /// windowless entry is never handed another window's hotkey on
    /// release, and a windowless holder's release hands it to nobody —
    /// before, nil matched every window, so either could leak the hotkey
    /// into another window's chat.
    func test_bus_releaseNeverHandsTheBusAcrossAnUnknownWindow() {
        let objectA = NSObject(), objectB = NSObject()
        let windowA = ObjectIdentifier(objectA), windowB = ObjectIdentifier(objectB)
        let main = UUID(), stray = UUID(), other = UUID()

        let bus = VoiceNoteCommandBus()
        bus.claimIfKey(stray, isKey: false, window: nil)
        bus.claim(main, window: windowA)
        bus.release(main)
        XCTAssertNil(bus.activeComposerID, "a composer of no known window never inherits window A's hotkey")

        let bus2 = VoiceNoteCommandBus()
        bus2.claim(other, window: windowB)
        bus2.claim(stray)
        bus2.release(stray)
        XCTAssertNil(bus2.activeComposerID, "releasing a windowless holder never hands window B's composer the hotkey")
        withExtendedLifetime((objectA, objectB)) {}
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

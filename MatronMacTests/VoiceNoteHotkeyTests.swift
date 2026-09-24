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
        bus.setRecording(composer, start: start)
        XCTAssertEqual(bus.recordingStart, start)
        bus.setRecording(composer, start: nil)
        XCTAssertNil(bus.recordingStart)
    }

    /// Only the recording composer may end its own recording on the bus:
    /// another composer's teardown must not clear an indicator it doesn't own.
    func test_bus_onlyTheRecordingComposerClearsTheRecording() {
        let bus = VoiceNoteCommandBus()
        let a = UUID(), b = UUID()
        bus.setRecording(a, start: Date())
        bus.setRecording(b, start: nil)
        XCTAssertNotNil(bus.recordingStart)
        bus.setRecording(a, start: nil)
        XCTAssertNil(bus.recordingStart)
    }

    /// Switching windows mid-note must not start a second capture: while
    /// any composer is recording, a press is addressed to IT, so the key
    /// window's composer stays out of it (Bugbot round 2, PR #182).
    func test_bus_pressTargetsTheRecordingComposerOverTheKeyWindow() {
        let bus = VoiceNoteCommandBus()
        let a = UUID(), b = UUID()
        bus.claim(a)
        bus.setRecording(a, start: Date())
        bus.claim(b)
        bus.press()
        XCTAssertEqual(bus.pressTarget, a, "the recording composer gets the stop-and-send")
        bus.setRecording(a, start: nil)
        bus.press()
        XCTAssertEqual(bus.pressTarget, b, "with nothing recording, the key window's composer starts")
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

    /// Coordinator panel (Task 14 fix round 1): two composers share a
    /// window. When the one holding the bus goes away, the bus goes back to
    /// the one before it IN THAT WINDOW — not to nothing (the hotkey went
    /// dead after closing the panel) and never to a released composer or
    /// another window's.
    func test_bus_releaseHandsTheBusBackToThePreviousClaimantInThatWindow() {
        let bus = VoiceNoteCommandBus()
        let windowA = NSObject(), windowB = NSObject()
        let main = UUID(), panel = UUID(), other = UUID()
        bus.claim(main, window: ObjectIdentifier(windowA))
        bus.claim(other, window: ObjectIdentifier(windowB))
        bus.claim(panel, window: ObjectIdentifier(windowA))
        bus.release(panel)
        XCTAssertEqual(bus.activeComposerID, main, "the window's remaining composer takes the bus back")
        bus.release(main)
        XCTAssertNil(bus.activeComposerID, "no composer left in window A: another window's does not inherit")
        bus.claim(panel, window: ObjectIdentifier(windowA))
        bus.release(panel)
        XCTAssertNil(bus.activeComposerID, "a released composer is never handed the bus again")
    }

    /// Bugbot B1 (PR #234): the Coordinator panel's composer never claims on
    /// mount, but it OFFERS itself — so when the main chat unmounts
    /// (Missions, Decisions) the window's hotkey falls back to it instead of
    /// going dead. An offer never steals a claim held in its window.
    func test_bus_offeredComposerInheritsWhenTheWindowsClaimantLeaves() {
        let bus = VoiceNoteCommandBus()
        // Kept alive: a freed object's identifier can be reused.
        let objectA = NSObject(), objectB = NSObject()
        let windowA = ObjectIdentifier(objectA), windowB = ObjectIdentifier(objectB)
        let main = UUID(), panel = UUID(), other = UUID()
        bus.claim(main, window: windowA)
        bus.offer(panel, isKey: true, window: windowA)
        XCTAssertEqual(bus.activeComposerID, main, "an offer never steals its window's claim")
        bus.release(main)
        XCTAssertEqual(bus.activeComposerID, panel, "the offered panel composer inherits the window's hotkey")

        // Alone in the key window from the start (panel opened over
        // Missions): it takes the bus from a background window's composer.
        let bus2 = VoiceNoteCommandBus()
        bus2.claim(other, window: windowB)
        bus2.offer(panel, isKey: true, window: windowA)
        XCTAssertEqual(bus2.activeComposerID, panel)
        // …but not while its window is in the background.
        let bus3 = VoiceNoteCommandBus()
        bus3.claim(other, window: windowB)
        bus3.offer(panel, isKey: false, window: windowA)
        XCTAssertEqual(bus3.activeComposerID, other)
        // A later claim (focus in the main composer) still wins.
        bus.claim(main, window: windowA)
        XCTAssertEqual(bus.activeComposerID, main)
        withExtendedLifetime((objectA, objectB)) {}
    }

    /// Bugbot (PR #234, VoiceNoteHotkey ~126): `WindowAccessor` can report a
    /// nil window first. A later non-nil window must refresh the entry —
    /// for a claimant that does not (re)take the bus, and for an offered
    /// composer — and never be overwritten by nil again; otherwise
    /// `release`'s same-window hand-back finds nobody.
    func test_bus_laterWindowRefreshesAnEntryFirstSeenWithoutOne() {
        let bus = VoiceNoteCommandBus()
        let objectA = NSObject()
        let windowA = ObjectIdentifier(objectA)
        let main = UUID(), panel = UUID()
        bus.claimIfKey(main, isKey: false, window: nil)      // unclaimed bus: taken, window unknown
        bus.offer(panel, isKey: false, window: nil)
        bus.claimIfKey(main, isKey: false, window: windowA)  // not key: no claim, but the window is learnt
        bus.offer(panel, isKey: false, window: windowA)
        bus.claimIfKey(main, isKey: false, window: nil)      // a stray nil never erases it
        XCTAssertEqual(bus.windowOf(main), windowA)
        XCTAssertEqual(bus.windowOf(panel), windowA)
        bus.release(main)
        XCTAssertEqual(bus.activeComposerID, panel)
        withExtendedLifetime(objectA) {}
    }

    /// …and an entry whose window never arrived still counts as the same
    /// window on release rather than stranding the hotkey.
    func test_bus_releaseToleratesAnEntryWithoutAWindow() {
        let bus = VoiceNoteCommandBus()
        let objectA = NSObject()
        let main = UUID(), panel = UUID()
        bus.claim(main, window: ObjectIdentifier(objectA))
        bus.offer(panel, isKey: false, window: nil)
        bus.release(main)
        XCTAssertEqual(bus.activeComposerID, panel)
        withExtendedLifetime(objectA) {}
    }

    /// Re-review #2852 item 1: back in a window whose only composer is the
    /// (unfocused) panel's, that composer takes the hotkey from another
    /// window — but never from a claimant of its own window.
    func test_bus_claimIfWindowUnclaimed() {
        let bus = VoiceNoteCommandBus()
        let objectA = NSObject(), objectB = NSObject()
        let windowA = ObjectIdentifier(objectA), windowB = ObjectIdentifier(objectB)
        let panel = UUID(), other = UUID(), main = UUID()
        bus.offer(panel, isKey: true, window: windowA)
        bus.claim(other, window: windowB)
        bus.claimIfWindowUnclaimed(panel, window: windowA)
        XCTAssertEqual(bus.activeComposerID, panel, "alone in its window: it takes the hotkey back")

        bus.claim(main, window: windowA)
        bus.claim(other, window: windowB)
        bus.claimIfWindowUnclaimed(panel, window: windowA)
        XCTAssertEqual(bus.activeComposerID, other, "the main chat of window A answers its own re-key")
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

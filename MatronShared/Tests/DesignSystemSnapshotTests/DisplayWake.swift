#if os(macOS)
import Foundation
import IOKit.pwr_mgt

/// Wakes the display and keeps it awake for the rest of the test run.
///
/// The render tests read pixels back from windows. While the Mac's display
/// sleeps, those reads come back blank: ink widths measure 0 pt and the
/// on-screen highlight checks find no tint. A run started over ssh or by an
/// agent on an idle Mac then fails tests that pass with the screen on.
/// Declaring user activity wakes the display, as `caffeinate -u` does, and
/// the assertion stops it from sleeping again until the process exits.
func keepDisplayAwake() {
    _ = displayWake
}

private let displayWake: Void = {
    var activity = IOPMAssertionID(0)
    IOPMAssertionDeclareUserActivity("Matron render tests" as CFString, kIOPMUserActiveLocal, &activity)
    var noSleep = IOPMAssertionID(0)
    IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                "Matron render tests" as CFString, &noSleep)
    // The window server takes a moment to bring the display back.
    Thread.sleep(forTimeInterval: 1)
}()
#endif

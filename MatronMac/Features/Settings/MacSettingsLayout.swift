#if os(macOS)
import CoreGraphics

/// Shared sizing for the Settings window's panes.
enum MacSettingsLayout {
    /// Every pane uses this width, so switching tabs only changes the
    /// window's height, as in the system's own Settings windows. Devices
    /// sets the floor: its list needs the room.
    static let paneWidth: CGFloat = 560
}
#endif

import AppKit
import CoreGraphics

/// Whether nobody can see the screen: the display is asleep or the session
/// is locked.
///
/// The lists' occlusion handling waits only for a window that has been on
/// screen and is then hidden, because a window that has never been shown
/// (a test host's, or one still opening) must keep drawing. An app launched
/// while the display is off never shows its window, so without this it
/// redrew and ran passes every 50 ms all night. When the screen is asleep
/// or locked, a hidden window counts as hidden even if it was never seen.
@MainActor
final class MacScreenState {
    static let shared = MacScreenState()

    /// The seam the lists read. Tests replace it.
    static var isAsleep: () -> Bool = { shared.asleep }

    private(set) var asleep: Bool
    private var displayAsleep: Bool
    private var locked: Bool
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    private init() {
        displayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        asleep = displayAsleep || locked

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping @MainActor (MacScreenState) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.asleep = self.displayAsleep || self.locked
            }
        }
        observers.append((center, token))
    }
}

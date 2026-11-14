import AppKit
import MatronJournal

/// Holds the journal socket open only while a window can be seen.
///
/// The decisions live in `SocketLifecyclePolicy`; this feeds it what AppKit
/// reports and applies the answer. While the socket is wanted (a visible
/// window, or the grace period after the last one went) it holds an activity
/// assertion, so App Nap cannot throttle the engine's ping watchdog and
/// backoff sleeper and a dropped socket is still noticed and replaced. When
/// every window is hidden, minimised or occluded past the grace, or the
/// machine sleeps, it ends sync and releases the assertion so the Mac can
/// idle. Coming back opens the socket again from the stored cursor.
@MainActor
final class MacSyncLifecycle {
    let userID: String
    private let engine: JournalSyncEngine
    private var policy = SocketLifecyclePolicy()
    private var activity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var deadlineTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var systemAsleep = false
    private var screensAsleep = false
    private var stopped = false

    init(userID: String, engine: JournalSyncEngine) {
        self.userID = userID
        self.engine = engine
    }

    func start() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification,
                     NSWindow.didExposeNotification,
                     NSWindow.willCloseNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observe(center, name) { _ in }
        }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        // Starts open (the app has just begun sync) and with the assertion
        // held; the first refresh starts the grace if nothing is on screen.
        beginActivity()
        refresh()
    }

    func stop() {
        stopped = true
        applyTask?.cancel()
        applyTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        endActivity()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ change: @escaping @MainActor (MacSyncLifecycle) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                // A closing window is still `isVisible` while its will-close
                // notification is delivered, so look again once it is gone.
                self.refresh()
                Task { @MainActor [weak self] in self?.refresh() }
            }
        }
        observers.append((center, token))
    }

    private func anyWindowVisible() -> Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            !(window is NSPanel) && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    private func refresh() {
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        policy.setWindowsVisible(anyWindowVisible(), at: now)
        policy.setAsleep(systemAsleep || screensAsleep, at: now)
        let decision = policy.decide(at: now)
        if policy.holdsActivity { beginActivity() } else { endActivity() }
        apply(decision)
        scheduleDeadline(now: now)
    }

    /// The close that comes from time passing alone. The assertion is still
    /// held here, so this timer is not throttled.
    private func scheduleDeadline(now: TimeInterval) {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = policy.nextDeadline else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, deadline - now)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Applied in order, so a close is never overtaken by the reconnect that
    /// follows it.
    private func apply(_ decision: SocketLifecyclePolicy.Decision) {
        guard decision != .keep else { return }
        let engine = engine
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            // Sign-out ends sync itself; a step queued behind a slow one
            // must not start it again afterwards.
            guard self?.stopped == false else { return }
            switch decision {
            case .keep:
                break
            case .close:
                await engine.endSync()
            case .reconnectFromCursor:
                await engine.beginSync()
                guard self?.stopped == false else { return }
                await engine.nudge()
                await engine.verifyConnection()
            }
        }
    }

    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .background,
            reason: "Matron keeps a live sync connection while a window is visible")
    }

    private func endActivity() {
        guard let token = activity else { return }
        ProcessInfo.processInfo.endActivity(token)
        activity = nil
    }
}

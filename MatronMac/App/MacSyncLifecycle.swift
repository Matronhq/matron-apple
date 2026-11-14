import AppKit
import MatronJournal
import MatronModels

/// The only thing on the Mac that starts and stops sync.
///
/// The decisions live in `SocketLifecyclePolicy`; this feeds it what AppKit
/// and the host report and applies the answer, one step at a time and in
/// order (a close finishes, and the old socket is gone, before the reconnect
/// that follows it begins).
///
/// - Coming forward: the socket opens when the app starts to activate, before
///   any window is drawn, and catches up from the stored cursor.
/// - Real events: it closes on system sleep and reopens on wake, and when the
///   displays sleep or the app leaves the foreground it closes after a grace
///   period (a fallback, so a glance away costs nothing). The engine's own
///   path monitor handles network changes while it runs.
/// - Work the user started needs no window: a voice note that is recording
///   or sending, or a queued outbox, keeps (or opens) the socket until it is
///   delivered.
/// - Quiet: a stop or reconnect made here is planned, so the connection
///   banner stays hidden unless a reconnect takes more than about two
///   seconds.
///
/// The process is held out of App Nap (an activity that still lets the Mac
/// sleep) only while the socket is open and no window on screen keeps the
/// app awake: during the grace, a voice note, or the user's "stay connected"
/// choice. Never while the socket is closed.
@MainActor
final class MacSyncLifecycle {
    /// UserDefaults key of the Settings toggle "Stay connected in the
    /// background". Off by default.
    static let stayConnectedKey = "matron.mac.stayConnectedInBackground"

    let userID: String
    private let engine: JournalSyncEngine
    private let quiet = QuietReconnect.shared
    private var policy = SocketLifecyclePolicy()
    private var activity: NSObjectProtocol?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var deadlineTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var voiceTailTask: Task<Void, Never>?
    private var probing = false
    private var systemAsleep = false
    private var appActive = false
    private var stopped = false

    private enum Step { case begin, close, reconnect }

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
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification,
                     NSApplication.didChangeOcclusionStateNotification,
                     NSApplication.didBecomeActiveNotification,
                     NSApplication.didHideNotification,
                     NSApplication.didUnhideNotification] {
            observe(center, name) { _ in }
        }
        // Before the window is drawn: coming forward is the cue to reconnect.
        observe(center, NSApplication.willBecomeActiveNotification) { $0.appActive = true }
        observe(center, NSApplication.didResignActiveNotification) { $0.appActive = false }
        observe(center, UserDefaults.didChangeNotification) { _ in }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { _ in }
        observe(workspace, NSWorkspace.willSleepNotification) { $0.systemAsleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemAsleep = false }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.policy.setDisplaysAsleep(true, at: $0.now) }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.policy.setDisplaysAsleep(false, at: $0.now) }

        // The quiet period ends when the engine has caught up.
        let engine = engine
        stateTask = Task { [weak self] in
            for await state in engine.stateStream() {
                if state == .running { self?.quiet.settled() }
            }
        }

        appActive = NSApp.isActive
        // Sync starts here and nowhere else on the Mac. The policy begins
        // with the socket open; the first refresh starts the grace if
        // nothing is in front of the user.
        enqueue(.begin)
        refresh()
    }

    func stop() {
        stopped = true
        applyTask?.cancel()
        applyTask = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        stateTask?.cancel()
        stateTask = nil
        voiceTailTask?.cancel()
        voiceTailTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        endActivity()
        quiet.settled()
    }

    /// A voice note is recording, starting or sending. It keeps the socket
    /// open, and opens it if it is closed, so the note is delivered with no
    /// window in front. The socket is released a few seconds after the last
    /// note settles, so the frame that carried it has left the machine.
    func setVoiceNoteActive(_ active: Bool) {
        guard !stopped else { return }
        voiceTailTask?.cancel()
        voiceTailTask = nil
        if active {
            policy.setVoiceNoteActive(true, at: now)
            refresh()
            return
        }
        guard policy.voiceNoteActive else { return }
        voiceTailTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !self.stopped, !Task.isCancelled else { return }
            self.policy.setVoiceNoteActive(false, at: self.now)
            self.refresh()
        }
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

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

    /// Real windows only: the app's own, that can become main, below the
    /// floating levels. A stray helper or system window that reports
    /// `isVisible` must not keep the socket open for good.
    private func anyWindowVisible() -> Bool {
        guard !NSApp.isHidden else { return false }
        return NSApp.windows.contains { window in
            window.canBecomeMain
                && window.level.rawValue < NSWindow.Level.floating.rawValue
                && window.isVisible && !window.isMiniaturized
                && window.occlusionState.contains(.visible)
        }
    }

    private func refresh(probed: Bool = false) {
        guard !stopped else { return }
        let now = now
        policy.setWindowsVisible(anyWindowVisible(), at: now)
        policy.setAppActive(appActive, at: now)
        policy.setAsleep(systemAsleep, at: now)
        policy.setStayConnected(UserDefaults.standard.bool(forKey: Self.stayConnectedKey), at: now)
        // Every close path looks at the outbox first: queued messages need
        // the socket, and the policy only knows what it was last told.
        if !probed, policy.wouldClose(at: now) {
            probeOutboxThenRefresh()
            return
        }
        let decision = policy.decide(at: now)
        if policy.holdsActivity { beginActivity() } else { endActivity() }
        switch decision {
        case .keep: break
        case .close:
            quiet.stopped()
            enqueue(.close)
        case .reconnectFromCursor:
            quiet.reconnectStarted()
            enqueue(.reconnect)
        }
        scheduleWake(now: now)
    }

    /// Reads the engine's outbox into the policy, then decides with it. The
    /// assertion stays as it was meanwhile (the socket is still open).
    private func probeOutboxThenRefresh() {
        guard !probing else { return }
        probing = true
        let engine = engine
        Task { [weak self] in
            let pending = await engine.hasPendingOutbox
            guard let self else { return }
            self.probing = false
            guard !self.stopped else { return }
            self.policy.setOutboxPending(pending, at: self.now)
            self.refresh(probed: true)
        }
    }

    /// The next time nothing else will prompt a look: the end of the grace or
    /// of the activation window, or a re-check of the outbox while it holds
    /// the socket. The assertion is held across both (the socket is open with
    /// nothing on screen), so this timer is not throttled.
    private func scheduleWake(now: TimeInterval) {
        deadlineTask?.cancel()
        deadlineTask = nil
        let delay: TimeInterval
        let probeOutbox: Bool
        if let deadline = policy.nextDeadline {
            delay = max(0, deadline - now)
            probeOutbox = false
        } else if policy.outboxPending {
            delay = 5
            probeOutbox = true
        } else {
            return
        }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !self.stopped, !Task.isCancelled else { return }
            if probeOutbox {
                self.probeOutboxThenRefresh()
            } else {
                self.refresh() // probes the outbox itself if this would close
            }
        }
    }

    /// Applied in order, so a close is never overtaken by the reconnect that
    /// follows it, and each restart starts after the old socket is gone
    /// (`endSync` returns once the old run loop has ended).
    private func enqueue(_ step: Step) {
        let engine = engine
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            // Sign-out ends sync itself; a step queued behind a slow one
            // must not start it again afterwards.
            guard self?.stopped == false else { return }
            switch step {
            case .begin:
                await engine.beginSync()
            case .close:
                await engine.endSync()
            case .reconnect:
                await engine.beginSync()
                guard self?.stopped == false else { return }
                await engine.nudge()
                await engine.verifyConnection()
            }
        }
    }

    /// `.userInitiatedAllowingIdleSystemSleep` keeps App Nap off the engine's
    /// timers (ping watchdog, backoff, the close deadline) while the socket
    /// is open without a window on screen, and still lets the Mac sleep.
    /// `.background` would not: it is the discretionary class and does not
    /// opt out of App Nap.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Matron keeps its sync connection open with no window on screen")
    }

    private func endActivity() {
        guard let token = activity else { return }
        ProcessInfo.processInfo.endActivity(token)
        activity = nil
    }
}

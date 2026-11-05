import Foundation
import MatronJournal

/// Whether a silent push should start a catch-up. The journal paces its wakes,
/// but a read on another device also sends one, and each wake iOS grants
/// counts against the app's budget, so one that would find nothing new ends
/// straight away.
enum SilentWakePolicy {
    static let minimumGap: TimeInterval = 5 * 60

    static func shouldCatchUp(inBackground: Bool, lastCatchUpEnded: Date?, now: Date) -> Bool {
        // In front, the live socket already has it.
        guard inBackground else { return false }
        guard let lastCatchUpEnded else { return true }
        return now.timeIntervalSince(lastCatchUpEnded) >= minimumGap
    }
}

/// One background catch-up: reconnect, let the journal replay what this device
/// missed (which also flushes queued sends), and stop in time for iOS.
///
/// Works from the process alone. iOS often relaunches a suspended app that it
/// has since evicted, straight into the background and with no window, so the
/// SwiftUI tree that normally restores the session and starts the sync engine
/// may not exist yet. It reads the session itself rather than relying on that
/// tree: a wake must do the same work on a cold launch as on a warm one. Signed
/// out, the stored session is gone and this does nothing.
@MainActor
enum BackgroundCatchUp {
    /// How long a silent push's run may last before reporting back, inside
    /// the 30 s iOS allows.
    static let silentPushDeadline: Duration = .seconds(27)
    /// How long to wait for the replay to reach the live cursor. Whatever
    /// lands before this is kept: the next wake or foreground resumes from
    /// the cursor it reached.
    private static let replayCap: Duration = .seconds(22)
    /// Lets in-flight journal frames and the outbox flush land.
    private static let settle: Duration = .seconds(2)

    static func run(dependencies: AppDependencies) async {
        // Installed by the window's bootstrap too; a cold background launch
        // has no window, and a parked engine needs this to hear of a resume.
        dependencies.installLifecycleHooks()
        // The phone may have locked (or unlocked) while this process was
        // suspended, with the notification missed: re-read before any search
        // write can happen.
        dependencies.refreshProtectedDataState(sceneIsActive: false)
        guard let restored = try? await dependencies.auth.restoreSession(),
              let engine = dependencies.syncService(for: restored) as? JournalSyncEngine
        else { return }
        // No-op when already running.
        try? await engine.start()
        await engine.nudge()
        // Before reading the state: a socket that died during the suspension
        // still reads as `.running`, and the wake would end here having
        // fetched nothing.
        await engine.verifyConnection()
        let alreadyCaughtUp = await engine.isConnectedAndCaughtUp
        // The cap is a racing task (not a check inside the loop) because a
        // stream that never yields again would otherwise block the wait until
        // the grant expires.
        let wait = Task {
            for await state in engine.stateStream() {
                if case .running = state { return }
            }
        }
        let cap = Task {
            try? await Task.sleep(for: replayCap)
            wait.cancel()
        }
        await wait.value
        cap.cancel()
        // Owed only when there was a catch-up or sends are still pending.
        var needsSettle = !alreadyCaughtUp
        if !needsSettle { needsSettle = await engine.hasPendingOutbox }
        if needsSettle {
            try? await Task.sleep(for: settle)
        }
    }
}

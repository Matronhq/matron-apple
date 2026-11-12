import BackgroundTasks
import MatronJournal
import os
import UIKit
import UserNotifications

/// `UIApplicationDelegate` adaptor for the SwiftUI host. SwiftUI's
/// `App` protocol doesn't expose
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`,
/// so iOS push registration needs a delegate. The adaptor on
/// `MatronApp` keeps an instance alive for the process lifetime;
/// SwiftUI hands the system the same instance APNs invokes when the
/// device token arrives or fails.
///
/// `MatronApp`'s push `.task` sets `registerDeviceToken` to a
/// closure that calls `JournalPushService.registerToken(...)` for the
/// active session; this delegate just forwards whatever token APNs hands
/// it. `registerDeviceToken` is `nil` until a session is signed in (or
/// after sign-out), in which case an early token delivery is dropped —
/// the delegate re-fires `didRegister...` any time
/// `registerForRemoteNotifications()` is called again, which the push
/// `.task` does on every session start.
///
/// `didFinishLaunchingWithOptions` also installs
/// `NotificationDelegate.shared` as the
/// `UNUserNotificationCenter` delegate so notification taps surface
/// `userNotificationCenter(_:didReceive:withCompletionHandler:)`,
/// which translates to a `tappedRoomID.send(...)` Combine event the
/// host observes to deep-link into the right chat.
final class MatronAppDelegate: NSObject, UIApplicationDelegate {
    /// BGAppRefresh identifier — must match
    /// `BGTaskSchedulerPermittedIdentifiers` in project.yml.
    static let refreshTaskID = "chat.matron.refresh"
    private static let logger = Logger(subsystem: "chat.matron", category: "app-delegate")

    /// Set by `MatronApp`'s push `.task` once a session is signed in.
    /// `@MainActor` isolation matches where both the setter (SwiftUI
    /// `.task`) and this delegate callback (APNs, on main) run.
    @MainActor var registerDeviceToken: ((Data) -> Void)?

    /// When the last background catch-up ended, in this process.
    @MainActor private static var lastCatchUpEnded: Date?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        #if DEBUG || MATRON_PERF_PROBE
        ScrollFramesProbe.startIfRequested()
        #endif
        // Before any chat exists, so the first one knows where the keyboard is.
        KeyboardFrameTracker.start()
        // BGTaskScheduler demands registration before launch finishes; the
        // handler body closes over `self` so `MatronApp` can install the
        // actual work later (exactly like the push-token callback).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID, using: nil
        ) { task in
            Self.handleRefresh(task as! BGAppRefreshTask)
        }
        // Database suspension (0xdead10cc): a launch straight into the
        // background (a BGAppRefresh wake) starts suspended until the
        // refresh claims its activity; a normal launch is `.inactive` here.
        // The foreground edge is observed at this level, not only in the
        // signed-in scene's phase handler, because a process that launched
        // in the background and is then opened to the sign-in screen has no
        // such handler — and would otherwise open the new session's store
        // into a suspension nobody lifts. The background edge stays with the
        // scene handler: it has to come after the outbox grace claims its
        // activity (see `OutboxBackgroundGrace.holdIfNeeded`).
        let launchedInBackground = application.applicationState == .background
        DatabaseSuspensionController.shared.setInBackground(launchedInBackground)
        // Scene-based apps have been seen to report `.background` here on an
        // ordinary foreground launch; if so, the databases start suspended
        // until the scene's first phase change resumes them. Logged so the
        // real value can be read off a device (subsystem chat.matron).
        Self.logger.info("launch applicationState=\(application.applicationState.rawValue, privacy: .public) databasesSuspended=\(DatabaseSuspensionController.shared.isSuspended, privacy: .public)")
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in
            DatabaseSuspensionController.shared.setInBackground(false)
        }
        return true
    }

    /// Asks iOS for a background wake so the journal can catch up (and the
    /// outbox flush) while the app isn't foregrounded. Called on every
    /// background transition and on each refresh firing; the OS coalesces
    /// duplicate submissions and paces actual wakes itself.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        // Denied submissions (background refresh off, low power) are not
        // actionable — the foreground reconnect path still covers catch-up.
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handleRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh() // always re-arm the next wake
        let run = startCatchUp { caughtUp in
            task.setTaskCompleted(success: caughtUp)
        }
        task.expirationHandler = {
            run.expire()
        }
    }

    /// A silent push from the journal. iOS allows about 30 s and then counts
    /// the wake against the app, and offers no expiry callback here, so the
    /// run's own deadline stands in for one.
    @MainActor
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Before the policy can end it: this counts what iOS delivered, which
        // is the only on-device evidence of whether wakes arrive at all.
        if application.applicationState == .background {
            AppRoot.dependencies.syncStats.noteBackgroundWake()
            Self.logger.info("silent wake delivered in background")
        }
        guard SilentWakePolicy.shouldCatchUp(
            inBackground: application.applicationState == .background,
            lastCatchUpEnded: Self.lastCatchUpEnded, now: Date()
        ) else {
            completionHandler(.noData)
            return
        }
        // `.failed` even on expiry would be wrong: a replay that runs out of
        // time keeps what it reached, and iOS may wake an app less often if
        // it reports failures.
        let run = Self.startCatchUp { _ in
            completionHandler(.newData)
        }
        Task {
            try? await Task.sleep(for: BackgroundCatchUp.silentPushDeadline)
            run.expire()
        }
    }

    /// Runs one background catch-up with the databases resumed, and calls
    /// `finished` exactly once: when it ends, or on expiry, whichever is
    /// first. iOS treats a wake that never reports back as a failed one, so
    /// expiry must not depend on the work unwinding promptly.
    private static func startCatchUp(finished: @escaping @Sendable (Bool) -> Void) -> CatchUpRun {
        // The catch-up writes the journal with the app backgrounded, so the
        // databases stay resumed for its lifetime and are suspended again as
        // it completes — normal path and expiry alike.
        let activity = DatabaseSuspensionController.shared.beginActivity(named: "bg-catch-up")
        let stats = AppRoot.dependencies.syncStats
        let completed = OSAllocatedUnfairLock(initialState: false)
        let completeOnce: @Sendable (Bool) -> Void = { success in
            let first = completed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            // This run's events and catch-up, which the write interval may
            // still be holding back.
            stats.flush()
            // Locks released before the wake is reported done: iOS may
            // suspend the process as soon as it is. `end()` is synchronous
            // and thread-safe — the expiry handler is not guaranteed to run
            // on the main thread.
            activity.end()
            let ended = Date()
            Task { @MainActor in lastCatchUpEnded = ended }
            finished(success)
        }
        let work = Task { @MainActor in
            await BackgroundCatchUp.run(dependencies: AppRoot.dependencies)
            completeOnce(true)
        }
        return CatchUpRun(expire: {
            work.cancel()
            completeOnce(false)
        })
    }

    private struct CatchUpRun: Sendable {
        let expire: @Sendable () -> Void
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            registerDeviceToken?(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Log only. iOS Simulator without a paired Mac signing setup hits
        // this every launch — not actionable from app code. Future
        // Settings UI surfaces persistent failures.
    }
}

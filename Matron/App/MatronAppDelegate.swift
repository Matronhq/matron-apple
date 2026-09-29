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
/// Task 11: the token flow is now direct rather than routed through
/// `PushTokenStore`/`PushBootstrap` (Matrix-SDK-only machinery this task
/// drops). `MatronApp`'s push `.task` sets `registerDeviceToken` to a
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

    /// Set by `MatronApp`'s push `.task` once a session is signed in.
    /// `@MainActor` isolation matches where both the setter (SwiftUI
    /// `.task`) and this delegate callback (APNs, on main) run.
    @MainActor var registerDeviceToken: ((Data) -> Void)?

    /// Background-refresh work, set by `MatronApp` once a session exists
    /// (nil before sign-in / after sign-out — the task then just
    /// reschedules). Same lifecycle pattern as `registerDeviceToken`.
    @MainActor var backgroundRefresh: (() async -> Void)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        // BGTaskScheduler demands registration before launch finishes; the
        // handler body closes over `self` so `MatronApp` can install the
        // actual work later (exactly like the push-token callback).
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshTaskID, using: nil
        ) { [weak self] task in
            Self.handleRefresh(task as! BGAppRefreshTask, delegate: self)
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
        DatabaseSuspensionController.shared.setInBackground(application.applicationState == .background)
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

    private static func handleRefresh(_ task: BGAppRefreshTask, delegate: MatronAppDelegate?) {
        scheduleBackgroundRefresh() // always re-arm the next wake
        // The catch-up writes the journal with the app backgrounded, so the
        // databases stay resumed for the task's lifetime and are suspended
        // again as it completes — normal path and expiry alike.
        let activity = DatabaseSuspensionController.shared.beginActivity(named: "bg-refresh")
        // Exactly-once completion shared by the normal path and the expiry
        // path: iOS treats a never-completed task as a failed background
        // execution, so expiry must not depend on the work task unwinding
        // promptly — and the work task finishing later must not complete a
        // second time (bugbot "BG expiry omits task completion").
        let completed = OSAllocatedUnfairLock(initialState: false)
        let completeOnce: @Sendable (Bool) -> Void = { success in
            let first = completed.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            // Locks released before the task is reported done: iOS may
            // suspend the process as soon as it is. `end()` is synchronous
            // and thread-safe — the expiry handler is not guaranteed to run
            // on the main thread.
            activity.end()
            task.setTaskCompleted(success: success)
        }
        let work = Task { @MainActor in
            await delegate?.backgroundRefresh?()
            completeOnce(true)
        }
        task.expirationHandler = {
            work.cancel()
            completeOnce(false)
        }
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

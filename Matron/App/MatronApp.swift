import SwiftUI
import UIKit
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem

@main
struct MatronApp: App {
    /// APNs token capture lives on the `UIApplicationDelegate`, not on the
    /// SwiftUI scene. The adaptor keeps a single delegate instance alive
    /// for the process lifetime so the system can hand
    /// `didRegisterForRemoteNotificationsWithDeviceToken` back to the same
    /// object every push registration cycle. Task 11 wires the delegate's
    /// `registerDeviceToken` callback directly to the journal
    /// `PushService` — see the push `.task` below.
    @UIApplicationDelegateAdaptor(MatronAppDelegate.self) private var appDelegate

    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// Phase 4 Task 6 — chat-list `NavigationStack` path. Hoisted to the
    /// host so a notification tap (routed via
    /// `NotificationDelegate.shared.tappedRoomID`) can append a room ID
    /// and SwiftUI's stack drives the existing
    /// `ChatListView.navigationDestination(for: ChatSummary.ID.self)`
    /// branch. `[String]` because `ChatSummary.ID == String`.
    @State private var chatPath: [String] = []
    /// Drives the scenePhase reconnect nudge below.
    @Environment(\.scenePhase) private var scenePhase
    /// In-app appearance override (System/Light/Dark). Written by the
    /// AppearancePicker in Settings → Device; applied here at the root so
    /// it covers the sign-in view and every sheet, not just the chat UI.
    @AppStorage(MatronAppearance.storageKey) private var appearanceRaw =
        MatronAppearance.system.rawValue
    /// Biometric app lock. Lives at the host (not per-session) because the
    /// lock guards the whole UI surface and must engage before any session
    /// content renders on a cold launch.
    @State private var appLock = AppLockController(auth: LocalBiometricAuthenticator())
    /// One automatic Face ID prompt per foreground stay — the prompt's own
    /// dismissal re-fires `.active`, so prompting from every `.active`
    /// transition would nag a user who cancelled in an endless loop.
    @State private var lockAutoPrompted = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .task { await bootstrap() }
                } else if let session {
                    NavigationStack(path: $chatPath) {
                        ChatListView(
                            viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                            onSignOut: { signOut() },
                            // Phase 6 (Search): a search result navigates by
                            // appending the room ID onto the stack path the
                            // host owns (same mechanism as a notification tap).
                            onOpenChat: { roomID in
                                if chatPath.last != roomID { chatPath.append(roomID) }
                            }
                        )
                    }
                    .environment(\.appDependencies, dependencies)
                    .environment(\.currentSession, session)
                    // Settings (a sheet off the chat list) reads this to
                    // render the Privacy section — sheets inherit the
                    // presenting hierarchy's environment.
                    .environment(\.appLockController, appLock)
                    // Lets the running-subagent strip / sub-chat switcher
                    // push a child chat or switch siblings on the same stack.
                    .environment(\.chatNavigationPath, $chatPath)
                    // Notification-tap deep link. The NSE-rewritten
                    // userInfo carries `room_id`; NotificationDelegate
                    // publishes that ID and we append it onto the
                    // navigation path so the existing
                    // `navigationDestination(for: ChatSummary.ID.self)`
                    // branch in ChatListView pushes the chat. Idempotent
                    // on duplicate sends.
                    .onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
                        if chatPath.last != roomID {
                            chatPath.append(roomID)
                        }
                    }
                    .task { try? await dependencies.syncService(for: session).start() }
                    // Auto-open a conversation the bridge just created while
                    // we're live (e.g. the user sent /start in another chat).
                    // The engine only emits ids for convos born while running,
                    // so this won't fire for the cold-start / reconnect
                    // backlog. Appends onto the same nav path a notification
                    // tap uses, so the new chat pushes into view without the
                    // user hunting for it in the list.
                    .task(id: session.userID) {
                        for await roomID in await dependencies.syncService(for: session).newConversations() {
                            if chatPath.last != roomID { chatPath.append(roomID) }
                        }
                    }
                    .task(id: session.userID) {
                        // Cold-start tap drain: if iOS launched the app
                        // specifically because the user tapped a
                        // notification on the lock screen, `didReceive`
                        // ran before the `.onReceive(tappedRoomID)` above
                        // subscribed and `PassthroughSubject` dropped the
                        // value. The delegate buffers such taps in
                        // `pendingRoomID`; drain it here.
                        if let pending = NotificationDelegate.shared.consumePendingRoomID(),
                           chatPath.last != pending {
                            chatPath.append(pending)
                        }
                    }
                    // Push pipeline: request permission, register for
                    // remote notifications, and wire the delegate's device-
                    // token callback straight to the journal server's
                    // `/push/register` endpoint (no client-provider /
                    // pusher-base dance needed — that was Matrix-SDK-only
                    // machinery Task 11 drops).
                    .task(id: session.userID) {
                        let pushService = dependencies.pushService(for: session)
                        appDelegate.registerDeviceToken = { token in
                            Task { try? await pushService.registerToken(token, pusherBaseURL: session.homeserverURL) }
                        }
                        _ = await pushService.requestPermission()
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    // Background-refresh work: when iOS grants a periodic
                    // wake, kick the reconnect and give the engine a
                    // bounded window to catch the journal up (which also
                    // flushes any queued sends). Same install-a-closure
                    // lifecycle as the push token callback above.
                    .task(id: session.userID) {
                        let dependencies = self.dependencies
                        appDelegate.backgroundRefresh = {
                            guard let engine = dependencies.syncService(for: session) as? JournalSyncEngine else { return }
                            await engine.nudge()
                            // Bounded readiness wait: consume the state
                            // stream until `.running`, with a hard ~15s
                            // cap. The cap is a racing task (not a check
                            // inside the loop) because a stream that never
                            // yields again would otherwise block the wait
                            // until the BG grant expires (bugbot
                            // "Background wait ignores deadline").
                            let wait = Task {
                                for await state in await engine.stateStream() {
                                    if case .running = state { return }
                                }
                            }
                            let cap = Task {
                                try? await Task.sleep(for: .seconds(15))
                                wait.cancel()
                            }
                            await wait.value
                            cap.cancel()
                            // Brief settle so in-flight journal frames and
                            // the outbox flush land before suspension.
                            try? await Task.sleep(for: .seconds(2))
                        }
                    }
                    // Reconnect nudge: when the app returns to the
                    // foreground, cancel the sync engine's backoff sleep so
                    // a stale connection retries immediately instead of
                    // waiting out whatever backoff interval it landed on
                    // while backgrounded. On the way OUT, schedule the
                    // periodic background refresh and — if sends are still
                    // awaiting confirmation — hold a short background grace
                    // so a send-then-pocket actually delivers.
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task { await (dependencies.syncService(for: session) as? JournalSyncEngine)?.nudge() }
                            appLock.noteBecameActive()
                            if appLock.isLocked, !lockAutoPrompted {
                                lockAutoPrompted = true
                                Task { await appLock.unlock() }
                            }
                        } else if phase == .background {
                            MatronAppDelegate.scheduleBackgroundRefresh()
                            OutboxBackgroundGrace.holdIfNeeded(
                                engine: dependencies.syncService(for: session) as? JournalSyncEngine)
                            // .background, not .inactive: a Control Center
                            // peek or the Face ID prompt itself briefly
                            // passes through .inactive and must not start
                            // the lock countdown.
                            appLock.noteResignedActive()
                            lockAutoPrompted = false
                        }
                        AppLockOverlay.update(controller: appLock, shield: appLock.isEnabled && phase != .active)
                    }
                    // The lock flips outside scenePhase changes too (unlock
                    // succeeds, settings toggles it) — keep the overlay
                    // window in step.
                    .onChange(of: appLock.isLocked) { _, _ in
                        AppLockOverlay.update(controller: appLock, shield: false)
                    }
                    // Cold launch while enabled starts locked before any
                    // scenePhase change fires: mount the overlay and offer
                    // the one automatic prompt here.
                    .task {
                        guard appLock.isLocked else { return }
                        AppLockOverlay.update(controller: appLock, shield: false)
                        if !lockAutoPrompted {
                            lockAutoPrompted = true
                            await appLock.unlock()
                        }
                    }
                } else {
                    let linkViewModel = LinkSignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS")
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        linkViewModel: linkViewModel,
                        rendezvousViewModel: RendezvousSignInViewModel(relay: RelayClient(), link: linkViewModel),
                        onSignedIn: { session in
                            // Gate the new session on any in-flight sign-out
                            // teardown: publishing it earlier would build a
                            // second journal core against the same SQLite
                            // file the old engine is still wiping (bugbot
                            // "Sign-out races fast re-login"). Then clear any
                            // mirror + search index a process death left on
                            // disk before the background wipe finished
                            // (bugbot "Sign-out leaves local mirror") — a
                            // fresh login resyncs from a server snapshot, so
                            // the clean slate costs nothing. Restore (see
                            // `bootstrap()`) deliberately skips this.
                            Task {
                                await dependencies.awaitPendingTeardown()
                                await dependencies.wipeLocalDataForFreshLogin()
                                self.session = session
                            }
                        }
                    )
                }
            }
            .preferredColorScheme(MatronAppearance(storedValue: appearanceRaw).colorScheme)
        }
    }

    /// Restores any persisted journal session (file-backed, keyed
    /// `"matron.journal.session"`); a first launch after this task simply
    /// finds no session and falls through to the SignInView. No migration
    /// from the old Matrix-SDK session store — Task 11 amendment 5.
    private func bootstrap() async {
        session = try? await dependencies.auth.restoreSession()
        bootstrapDone = true
    }

    /// Sign-out path. Drops the in-memory session state and clears the
    /// persisted session + per-session journal caches via
    /// `AppDependencies.signOut()` — the resulting `session == nil` branch
    /// re-mounts the SignInView.
    private func signOut() {
        dependencies.signOut()
        session = nil
        // Detach APNs from the dead session: the token callback captured
        // its push service, so a late registration callback would post the
        // device token against the signed-out account (bugbot "Push
        // callback survives sign-out"). The next session's push .task
        // installs a fresh one.
        appDelegate.registerDeviceToken = nil
        // Same lifecycle as the token callback: a background refresh firing
        // after sign-out must not reopen the previous account's journal
        // mid-wipe (bugbot "Stale refresh after sign-out"). The next
        // session's .task installs a fresh closure.
        appDelegate.backgroundRefresh = nil
        // Drop any deep-linked room from the prior session so the next
        // sign-in lands at the chat list root, not stranded inside a
        // (now-inaccessible) prior-account room.
        chatPath = []
        // Drop any buffered cold-start tap so the next sign-in's task
        // doesn't drain a stale room ID from the prior account.
        NotificationDelegate.shared.clearPendingRoomID()
    }
}

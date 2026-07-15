import SwiftUI
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem

@main
struct MatronMacApp: App {
    /// Phase 4 Tasks 10/11 — APNs token capture + UN center delegate
    /// installation. The adaptor keeps a single delegate instance
    /// alive for the process lifetime; `applicationDidFinishLaunching`
    /// installs the shared `MacNotificationHandler` as the
    /// `UNUserNotificationCenter` delegate so taps surface from launch.
    /// Task 12 wires the delegate's `registerDeviceToken` callback
    /// directly to the journal `PushService` — see the push `.task`
    /// below and iOS `MatronApp` for the parallel wiring.
    @NSApplicationDelegateAdaptor(MatronMacAppDelegate.self) private var appDelegate

    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// In-app appearance override (System/Light/Dark). Written by the
    /// AppearancePicker in Settings → Device; applied to `NSApp.appearance`
    /// (below) rather than per-window so the Settings scene, alerts, and
    /// menus all switch together.
    @AppStorage(MatronAppearance.storageKey) private var appearanceRaw =
        MatronAppearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .frame(width: 480, height: 360)
                        .task { await bootstrap() }
                } else if let session {
                    // Sign-Out closure (Wave 6 / live-test #1). Listener
                    // moved INTO `MacChatListView` because the prior
                    // WindowGroup-root `.onReceive(...)` on a
                    // type-switching `Group { … }` silently dropped
                    // notifications on macOS — so the menu item posted to
                    // the bus but nothing observed it. Anchoring the
                    // listener on this signed-in branch view is the
                    // reliable shape; the host still owns the side effect
                    // via this closure.
                    MacChatListView(
                        viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                        onSignOut: { signOut(activeSession: session) }
                    )
                    .frame(minWidth: 800, minHeight: 600)
                    .environment(\.appDependencies, dependencies)
                    .environment(\.currentSession, session)
                    .task { try? await dependencies.syncService(for: session).start() }
                    // Push pipeline: request permission, register for
                    // remote notifications, and wire the delegate's
                    // device-token callback straight to the journal
                    // server's `/push/register` endpoint (no client-
                    // provider / pusher-base dance needed — that was
                    // Matrix-SDK-only machinery Task 12 drops). Mirrors
                    // iOS `MatronApp`'s push `.task`.
                    .task(id: session.userID) {
                        let pushService = dependencies.pushService(for: session)
                        appDelegate.registerDeviceToken = { token in
                            Task { try? await pushService.registerToken(token, pusherBaseURL: session.homeserverURL) }
                        }
                        _ = await pushService.requestPermission()
                        NSApplication.shared.registerForRemoteNotifications()
                    }
                    // Foreground reconnect nudge: when the app returns to
                    // active, cancel the sync engine's backoff sleep so a
                    // stale connection retries immediately instead of
                    // waiting out whatever backoff interval it landed on
                    // while inactive. `NSApplication.didBecomeActiveNotification`
                    // is the Mac equivalent of iOS's `scenePhase == .active`.
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                        Task { await (dependencies.syncService(for: session) as? JournalSyncEngine)?.nudge() }
                    }
                    // App Nap suppression: an idle/unfocused Mac app gets its
                    // timers and runloop throttled, which freezes the journal
                    // engine's ping watchdog and backoff sleeper — a silently
                    // dropped socket is then neither detected nor reconnected,
                    // and the chat list sits stale until the user clicks the
                    // window. Holding a `.background` activity for the
                    // lifetime of the signed-in session opts the process out
                    // of App Nap (lowest-impact option: it doesn't block
                    // display or system sleep).
                    .task(id: session.userID) {
                        let token = ProcessInfo.processInfo.beginActivity(
                            options: .background,
                            reason: "Matron keeps a live sync connection while signed in")
                        defer { ProcessInfo.processInfo.endActivity(token) }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(3600))
                        }
                    }
                } else {
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        onSignedIn: { session in
                            // Gate the new session on any in-flight sign-out
                            // teardown so a fast re-login can't open a second
                            // writer against the old session's store (bugbot
                            // "Sign-out races fast re-login"). Mirrors iOS.
                            Task {
                                await dependencies.awaitPendingTeardown()
                                self.session = session
                            }
                        }
                    )
                }
            }
            // Applies the override at launch (`initial: true`) and live
            // whenever the Settings picker rewrites the stored value.
            .onChange(of: appearanceRaw, initial: true) { _, raw in
                NSApp.appearance = MatronAppearance(storedValue: raw).nsAppearance
            }
        }
        .windowResizability(.contentMinSize)
        // Fresh-install window size. macOS restores the user's own frame
        // on subsequent launches, so this only seeds the first one.
        .defaultSize(width: 1280, height: 860)
        // Hide the window title ("Matron", the app display name) in the
        // header — the toolbar's chat title is the header's real content.
        // The title still exists for Mission Control / the Window menu.
        .windowToolbarStyle(.unified(showsTitle: false))
        // Mac menu bar — File / Edit / View / Help shortcuts that post
        // to a `NotificationCenter` command bus. See `Commands.swift`
        // for the keyboard shortcuts and notification names.
        .commands { ChatCommands() }

        // Settings → Device. Read-only account summary + Sign Out — see
        // `MacDeviceSettingsView` for the Task 12 rationale (this is the
        // view's new home now that the Help → Show Recovery Key… route
        // that used to present it is gone).
        Settings {
            if let session {
                MacDeviceSettingsView(session: session, onSignOut: { signOut(activeSession: session) })
            } else {
                Text("Sign in to view settings.")
                    .padding()
                    .frame(width: 420, height: 200)
            }
        }
    }

    /// Restores any persisted journal session (file-backed, keyed
    /// `"matron.journal.session"`); a first launch after this task simply
    /// finds no session and falls through to the sign-in view. No
    /// migration from the old Matrix-SDK session store.
    private func bootstrap() async {
        session = try? await dependencies.auth.restoreSession()
        bootstrapDone = true
    }

    /// Sign-out side effect, mirroring the iOS host's `signOut()`. Drops
    /// the in-memory session state and clears the persisted session +
    /// per-session journal caches via `AppDependencies.signOut()` — the
    /// resulting `session == nil` branch re-mounts the sign-in view.
    private func signOut(activeSession: UserSession) {
        dependencies.signOut()
        session = nil
        // Detach APNs from the dead session — a late token callback would
        // register against the signed-out account (bugbot "Push callback
        // survives sign-out"). The next session's push .task reinstalls it.
        appDelegate.registerDeviceToken = nil
        // Drop any buffered cold-start tap so the next sign-in's task
        // doesn't drain a stale room ID from the prior account.
        MacNotificationHandler.shared.clearPendingRoomID()
    }
}

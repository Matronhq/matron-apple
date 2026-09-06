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
    /// Global voice-note hotkey (Settings → Device → Voice note key): the
    /// Carbon registration, the bus the composer listens on, and the
    /// floating "Recording" indicator. All three live at the root because
    /// the key must work with no chat window focused at all.
    @AppStorage(VoiceNoteHotkeyKey.storageKey) private var voiceHotkeyRaw = VoiceNoteHotkeyKey.default.rawValue
    @State private var voiceBus = VoiceNoteCommandBus()
    @State private var voiceHotkey: VoiceNoteHotkeyRegistrar?
    @State private var voicePanel = VoiceNoteRecordingPanel()

    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// In-app appearance override (System/Light/Dark). Written by the
    /// AppearancePicker in Settings → Device; applied to `NSApp.appearance`
    /// (below) rather than per-window so the Settings scene, alerts, and
    /// menus all switch together.
    @AppStorage(MatronAppearance.storageKey) private var appearanceRaw =
        MatronAppearance.system.rawValue
    /// Biometric app lock (Touch ID with password fallback). Host-level
    /// because it guards every scene — the chat window and Settings both
    /// mount its overlay.
    @State private var appLock = AppLockController(auth: LocalBiometricAuthenticator())
    /// One automatic auth prompt per activation stay, mirroring iOS: a
    /// user who cancelled shouldn't be re-prompted until they leave and
    /// come back.
    @State private var lockAutoPrompted = false

    init() {
        // Opt out of macOS 26's floating glass sidebar and keep the
        // classic attached style (Dan, 2026-07-15: the floating pane's
        // big drop shadow leaks into the conversation, and there is no
        // public per-item API to tune it — NSSplitViewItem gained only
        // `automaticallyAdjustsSafeAreaInsets` in the 26 SDK). AppKit
        // reads this key through the app's standard defaults, so
        // registering it here scopes the override to Matron alone; it
        // must land before the first NSSplitViewItem is created, hence
        // App.init rather than applicationDidFinishLaunching. Unknown
        // (harmless) on macOS 15.
        UserDefaults.standard.register(defaults: [
            "NSSplitViewItemSidebarDefaultsToFloatingAppearance": false
        ])
        #if DEBUG
        DebugSnapshot.armIfRequested()
        #endif
    }

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
                        appLock.noteBecameActive()
                        // Foreground re-prompt parity with iOS: returning
                        // to a still-locked app offers auth again instead
                        // of stranding the user on the manual button
                        // (bugbot "Mac lacks foreground re-prompt").
                        if appLock.isLocked, !lockAutoPrompted {
                            lockAutoPrompted = true
                            Task { await appLock.unlock() }
                        }
                    }
                    // Cold-launch automatic prompt: at launch,
                    // didBecomeActive fires before this branch exists (the
                    // session restores asynchronously), so the .task owns
                    // the first prompt — same split as iOS.
                    .task {
                        guard appLock.isLocked, !lockAutoPrompted else { return }
                        lockAutoPrompted = true
                        await appLock.unlock()
                    }
                    // Lock countdown starts when Matron stops being the
                    // frontmost app. Anchored on this signed-in branch view
                    // (not the type-switching Group) — see the sign-out
                    // listener note above for why root-level onReceive
                    // silently drops notifications on macOS.
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
                        appLock.noteResignedActive()
                        // The system auth dialog deactivates the app when
                        // it appears (isUnlocking covers that) and can
                        // churn resign/activate once more as it tears
                        // down after a CANCEL — by then isUnlocking is
                        // already false, so also ignore resigns landing
                        // within a second of a still-locked attempt
                        // finishing (bugbot "Mac cancel re-triggers
                        // unlock prompts"). Scoped to isLocked: after a
                        // successful unlock the same window must not
                        // swallow a genuine quick departure, or the next
                        // locked return would skip its automatic prompt
                        // (bugbot "Mac skips auto unlock prompt") — and
                        // clearing the latch while unlocked is harmless,
                        // since prompts only ever fire when locked.
                        let dialogChurn = appLock.isUnlocking
                            || (appLock.isLocked
                                && (appLock.lastAuthEndedAt.map { Date().timeIntervalSince($0) < 1 } ?? false))
                        if !dialogChurn { lockAutoPrompted = false }
                    }
                    .environment(\.appLockController, appLock)
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
                    let linkViewModel = LinkSignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac")
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        linkViewModel: linkViewModel,
                        rendezvousViewModel: RendezvousSignInViewModel(relay: RelayClient(), link: linkViewModel),
                        onSignedIn: { session in
                            // Gate the new session on any in-flight sign-out
                            // teardown so a fast re-login can't open a second
                            // writer against the old session's store (bugbot
                            // "Sign-out races fast re-login"). Then clear any
                            // mirror + search index a process death left on
                            // disk before the background wipe finished
                            // (bugbot "Sign-out leaves local mirror") — a
                            // fresh login resyncs from a server snapshot, so
                            // the clean slate costs nothing. Restore skips
                            // this. Mirrors iOS.
                            Task {
                                await dependencies.awaitPendingTeardown()
                                await dependencies.wipeLocalDataForFreshLogin()
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
            .environment(voiceBus)
            // Register the global key at launch and whenever the Device
            // settings picker changes it. A press with no composer on
            // screen (no chat open) is refused audibly here, since the
            // composer's own handler can't run when there is none.
            .onChange(of: voiceHotkeyRaw, initial: true) { _, raw in
                let registrar = voiceHotkey ?? VoiceNoteHotkeyRegistrar { [voiceBus] in
                    if voiceBus.hasComposer {
                        voiceBus.press()
                    } else {
                        VoiceNoteCommandBus.playRefuseSound()
                    }
                }
                voiceHotkey = registrar
                registrar.register(VoiceNoteHotkeyKey(rawValue: raw) ?? .default)
            }
            .onChange(of: voiceBus.recordingStart) { _, start in
                if let start {
                    voicePanel.show(start: start, hotkey: VoiceNoteHotkeyKey(rawValue: voiceHotkeyRaw) ?? .default)
                } else {
                    voicePanel.hide()
                }
            }
            // Gated on a live session: pre-bootstrap and the sign-in view
            // hold nothing worth hiding, and a cold-launch lock would
            // otherwise sit over the sign-in form.
            .overlay {
                if appLock.isLocked, session != nil {
                    MacLockOverlay(controller: appLock)
                }
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

        // Settings (⌘,), three tabs:
        // - General: read-only account summary + appearance + Sign Out —
        //   see `MacDeviceSettingsView` for the Task 12 rationale.
        // - Devices: the journal device roster + agent pairing (journal
        //   PR #19 spec). Self-revocation routes through the same
        //   `signOut` as the button on the General tab.
        // - Link a Device: show-QR flow so a second device can sign in
        //   without retyping credentials (Task 6 of the QR device-link
        //   plan). Mac only shows codes — see `MacDeviceLinkView`.
        // - Agent Chats: requests from one agent to talk to another that are
        //   still waiting on a decision.
        Settings {
            Group {
                if let session {
                    TabView {
                        MacDeviceSettingsView(session: session, onSignOut: { signOut(activeSession: session) })
                            .tabItem { Label("General", systemImage: "gearshape") }
                            .environment(\.appLockController, appLock)
                        MacDevicesView(
                            api: dependencies.devicesService(for: session),
                            onSelfRevoked: { signOut(activeSession: session) }
                        )
                        .tabItem { Label("Devices", systemImage: "laptopcomputer.and.iphone") }
                        MacDeviceLinkView(
                            api: dependencies.deviceLinkService(for: session),
                            serverURL: session.homeserverURL
                        )
                        .tabItem { Label("Link a Device", systemImage: "qrcode") }
                        MacAgentChatView(api: dependencies.agentChatService(for: session))
                            .tabItem { Label("Agent Chats", systemImage: "person.2.wave.2") }
                    }
                } else {
                    Text("Sign in to view settings.")
                        .padding()
                        .frame(width: 420, height: 200)
                }
            }
            // Settings is its own window: without this overlay, ⌘, while
            // locked would expose account details — and the Privacy toggle
            // that turns the lock off.
            .overlay {
                if appLock.isLocked, session != nil {
                    MacLockOverlay(controller: appLock)
                }
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
        // The File → Sign Out menu command routes here through the command
        // bus, which the in-window lock overlay can't intercept — without
        // this guard a passerby could wipe a locked app's session (and its
        // queued outbox) from the menu bar (bugbot "Menu sign-out bypasses
        // lock"). Unlock first, then sign out.
        guard !appLock.isLocked else { return }
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

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
                    // Reconnect nudge: when the app returns to the
                    // foreground, cancel the sync engine's backoff sleep so
                    // a stale connection retries immediately instead of
                    // waiting out whatever backoff interval it landed on
                    // while backgrounded.
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task { await (dependencies.syncService(for: session) as? JournalSyncEngine)?.nudge() }
                        }
                    }
                } else {
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        linkViewModel: LinkSignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        onSignedIn: { session in
                            // Gate the new session on any in-flight sign-out
                            // teardown: publishing it earlier would build a
                            // second journal core against the same SQLite
                            // file the old engine is still wiping (bugbot
                            // "Sign-out races fast re-login").
                            Task {
                                await dependencies.awaitPendingTeardown()
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
        // Drop any deep-linked room from the prior session so the next
        // sign-in lands at the chat list root, not stranded inside a
        // (now-inaccessible) prior-account room.
        chatPath = []
        // Drop any buffered cold-start tap so the next sign-in's task
        // doesn't drain a stale room ID from the prior account.
        NotificationDelegate.shared.clearPendingRoomID()
    }
}

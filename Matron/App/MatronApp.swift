import SwiftUI
import MatronAuth
import MatronModels
import MatronVerification
import MatronViewModels

@main
struct MatronApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// Onboarding step-2 gate (Phase 3 / spec §5.2). Sign-in lands the user
    /// in this view-model; once `verifyDone` flips true (either after a
    /// successful verification flow or because the persisted flag was
    /// already set on relaunch), the chat list becomes reachable. Per-user
    /// scope lives in the `UserDefaults` key — see
    /// `PostLoginVerificationView.verifyDoneKey(for:)`.
    @State private var verifyDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .task { await bootstrap() }
                } else if let session {
                    if verifyDone {
                        // Build the verification orchestrator once per
                        // (session, scene) pair. `VerificationCenter`'s
                        // `start()` / `stop()` lifecycle is wired inside
                        // `ChatListView` so the long-lived
                        // `incomingRequests()` stream doesn't outlive the
                        // host view (Swift 6 strict concurrency forbids a
                        // `@MainActor deinit` reaching isolated state).
                        // The cached `verificationService(for:)` is
                        // load-bearing — the SAME instance is later passed
                        // to `ChatListView`, `ChatView` (per-bot banner),
                        // and `DeviceSettingsView` so they all share a
                        // FlowStore + the registered SDK delegate.
                        let verificationCenter = VerificationCenter(
                            service: dependencies.verificationService(for: session)
                        )
                        NavigationStack {
                            ChatListView(
                                viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                                onSignOut: { signOut() },
                                verificationCenter: verificationCenter
                            )
                        }
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        .task { try? await dependencies.syncService(for: session).start() }
                        // VerificationServiceLive.start() fetches the SDK's
                        // session-verification controller and registers the
                        // `LiveSessionVerificationDelegate` that drives
                        // `incomingRequests()` + every `.readyForEmoji([…])`
                        // / `.verified` / `.cancelled` SAS state transition.
                        // Without it, the chat-list banner is silent and
                        // every SAS sheet hangs at "Starting verification…"
                        // (expert-QA finding B1). Idempotent — safe on
                        // SwiftUI re-mounts.
                        .task { try? await dependencies.verificationService(for: session).start() }
                    } else {
                        PostLoginVerificationView(
                            dependencies: dependencies,
                            session: session,
                            onCompleted: { markVerifyDone(for: session) }
                        )
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        // Bugbot caught: SAS verification needs the sliding-sync
                        // session running to exchange to-device events with the
                        // other device. Previously sync only started on the
                        // post-verify branch; the verify-with-other-device flow
                        // would hang because nothing was talking to the server.
                        .task { try? await dependencies.syncService(for: session).start() }
                        // Mirrors the post-verify branch — without start()
                        // the post-login verify-with-other-device flow
                        // hangs at "Starting verification…" because no
                        // SDK delegate is wired (expert-QA finding B1).
                        .task { try? await dependencies.verificationService(for: session).start() }
                    }
                } else {
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        onSignedIn: { session in
                            self.session = session
                            // Restore any prior verifyDone state for this
                            // user so a re-sign-in doesn't re-prompt them.
                            self.verifyDone = UserDefaults.standard.bool(
                                forKey: PostLoginVerificationView.verifyDoneKey(for: session)
                            )
                        }
                    )
                }
            }
        }
    }

    private func bootstrap() async {
        do {
            session = try await dependencies.auth.restoreSession()
            // Restore the verify-done flag for the bootstrapped session
            // so a relaunch with an existing session lands directly in
            // the chat list rather than the verification gate.
            if let session {
                verifyDone = UserDefaults.standard.bool(
                    forKey: PostLoginVerificationView.verifyDoneKey(for: session)
                )
            }
        } catch {
            session = nil
        }
        bootstrapDone = true
    }

    /// Persists the verify-done flag for the active session and flips the
    /// in-memory state so the host swaps from `PostLoginVerificationView`
    /// to the chat list. Per-user scoping lives in the key — multi-account
    /// scenarios won't trample each other's flags.
    private func markVerifyDone(for session: UserSession) {
        UserDefaults.standard.set(true, forKey: PostLoginVerificationView.verifyDoneKey(for: session))
        verifyDone = true
    }

    /// Sign-out path. Phase-7 spec lands a full Settings → Account → Sign
    /// Out flow; Phase 2 wires the menu / toolbar hook now (QA finding
    /// #7) so swapping accounts on iOS doesn't require deleting the
    /// app's Application Support directory. Drops the in-memory session
    /// state and clears the persisted session + caches via
    /// `AppDependencies.signOut()` — the resulting `session == nil`
    /// branch re-mounts the SignInView.
    ///
    /// Phase 3 also clears the persisted verify-done flag for the active
    /// session so the next sign-in (with a different account, or the
    /// same one after a deliberate reset) re-runs the gate. Without this
    /// the gate would silently no-op for a user who signed out + back in
    /// to retry verification.
    private func signOut() {
        if let session {
            UserDefaults.standard.removeObject(forKey: PostLoginVerificationView.verifyDoneKey(for: session))
        }
        dependencies.signOut()
        session = nil
        verifyDone = false
    }
}

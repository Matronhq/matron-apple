import SwiftUI
import MatronAuth
import MatronModels
import MatronVerification
import MatronViewModels

@main
struct MatronMacApp: App {
    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// Mac mirror of `MatronApp.verifyDone` — onboarding step-2 gate.
    /// See `MacPostLoginVerificationView.verifyDoneKey(for:)` for the
    /// per-user `UserDefaults` scoping.
    @State private var verifyDone = false

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .frame(width: 480, height: 360)
                        .task { await bootstrap() }
                } else if let session {
                    if verifyDone {
                        // Build the verification orchestrator once per
                        // (session, scene) pair. `VerificationCenter`'s
                        // `start()` / `stop()` lifecycle is wired inside
                        // `MacChatListView` so the long-lived
                        // `incomingRequests()` stream doesn't outlive the
                        // host view (Swift 6 strict concurrency forbids a
                        // `@MainActor deinit` reaching isolated state).
                        let verificationCenter = VerificationCenter(
                            service: VerificationServiceLive(
                                provider: dependencies.clientProvider,
                                session: session
                            )
                        )
                        MacChatListView(
                            viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                            verificationCenter: verificationCenter
                        )
                        .frame(minWidth: 800, minHeight: 600)
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        .task { try? await dependencies.syncService(for: session).start() }
                    } else {
                        MacPostLoginVerificationView(
                            dependencies: dependencies,
                            session: session,
                            onCompleted: { markVerifyDone(for: session) }
                        )
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                    }
                } else {
                    MacSignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron Mac"),
                        onSignedIn: { session in
                            self.session = session
                            self.verifyDone = UserDefaults.standard.bool(
                                forKey: MacPostLoginVerificationView.verifyDoneKey(for: session)
                            )
                        }
                    )
                }
            }
            // Sign Out menu / toolbar: clear the persisted session, drop
            // in-memory caches, and flip `session = nil` so the SignInView
            // re-mounts. Without this listener the menu item posted to
            // the command bus but nothing observed it — sign-out was
            // silently a no-op (QA finding #2 + #7). Listener lives on
            // the WindowGroup root so it's attached regardless of which
            // child view (chat list, sign-in, verify gate) is on screen.
            //
            // Phase 3 also clears the persisted verify-done flag so a
            // deliberate sign-out + back-in re-runs the verification gate
            // (e.g. retrying after a botched verify on the prior login).
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.signOut))) { _ in
                if let session {
                    UserDefaults.standard.removeObject(
                        forKey: MacPostLoginVerificationView.verifyDoneKey(for: session)
                    )
                }
                dependencies.signOut()
                session = nil
                verifyDone = false
            }
        }
        .windowResizability(.contentMinSize)
        // Mac menu bar — File / Edit / View / Help shortcuts that post
        // to a `NotificationCenter` command bus. See `Commands.swift`
        // for the keyboard shortcuts and notification names.
        .commands { ChatCommands() }

        // Placeholder — Phase 7 fills in the full Settings UI. Phase 2
        // ships Sign Out via the File menu (`Commands.swift`), so even
        // without a Settings UI the user can swap accounts.
        Settings {
            Text("Settings — Phase 7 fills this in.")
                .padding()
                .frame(width: 480, height: 240)
        }
    }

    private func bootstrap() async {
        do {
            session = try await dependencies.auth.restoreSession()
            if let session {
                verifyDone = UserDefaults.standard.bool(
                    forKey: MacPostLoginVerificationView.verifyDoneKey(for: session)
                )
            }
        } catch {
            session = nil
        }
        bootstrapDone = true
    }

    /// Persists + flips the verify-done flag, mirroring the iOS host's
    /// `markVerifyDone(for:)`. See `MatronApp` for rationale.
    private func markVerifyDone(for session: UserSession) {
        UserDefaults.standard.set(true, forKey: MacPostLoginVerificationView.verifyDoneKey(for: session))
        verifyDone = true
    }
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).

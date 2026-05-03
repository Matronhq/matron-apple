import SwiftUI
import MatronAuth
import MatronModels
import MatronStorage
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
    /// Help → Verify This Device… sheet visibility. Flipped by the
    /// `.matronCommand(.verifyDevice)` listener on the WindowGroup root
    /// (Phase 3 / Task 9c). Sheet body builds a fresh self-verification
    /// SAS flow on each present, mirroring `MacPostLoginVerificationView`.
    @State private var showVerifyDeviceSheet = false
    /// Help → Show Recovery Key… sheet visibility. Flipped by the
    /// `.matronCommand(.showRecoveryKey)` listener on the WindowGroup
    /// root (Phase 3 / Task 9c). Phase 3 wires the menu surface; Task 11
    /// fills in the actual re-auth-then-reveal body.
    @State private var showRecoveryKeySheet = false

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
                        // Bugbot caught: SAS verification needs the sliding-sync
                        // session running to exchange to-device events with the
                        // other device. Previously sync only started on the
                        // post-verify branch; the verify-with-other-device flow
                        // would hang because nothing was talking to the server.
                        .task { try? await dependencies.syncService(for: session).start() }
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
            // Help → Verify This Device… (Phase 3 / Task 9c). The menu
            // item posts the notification; the listener flips the sheet
            // open. Listener lives on the WindowGroup root so it's
            // attached regardless of which child view is on screen — but
            // the sheet body short-circuits to a "sign in first" message
            // when no `session` is set so the menu item is harmless from
            // the SignInView state. Mirrors `.signOut` listener wiring.
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.verifyDevice))) { _ in
                showVerifyDeviceSheet = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.showRecoveryKey))) { _ in
                showRecoveryKeySheet = true
            }
            .sheet(isPresented: $showVerifyDeviceSheet) {
                if let session {
                    verifyDeviceSheet(for: session)
                } else {
                    Text("Sign in first to verify this device.")
                        .frame(width: 360, height: 120)
                        .padding()
                }
            }
            .sheet(isPresented: $showRecoveryKeySheet) {
                if let session {
                    showRecoveryKeySheetBody(for: session)
                } else {
                    Text("Sign in first to view your recovery key.")
                        .frame(width: 360, height: 120)
                        .padding()
                }
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

    /// Help → Verify This Device… sheet body. Builds a fresh
    /// self-verification SAS flow against the active session, mirroring
    /// the construction inside `MacPostLoginVerificationView` (Task 7).
    /// `requestID` is the user's matrix ID — that's the cache key
    /// `VerificationServiceLive.startSAS` registers under for
    /// self-verification flows; using it here makes confirm/cancel route
    /// back to the same FlowStore entry.
    ///
    /// Plan §9c describes a "no other device reachable → fall back to
    /// recovery-key restore" branch. Implementing the live device-list
    /// query needs the SDK device-fetch surface (out of scope for the
    /// menu wire-up), so today the sheet always presents `MacSasView` —
    /// if no other device responds, the SAS flow surfaces the timeout /
    /// cancellation back to the user via the same `.cancelled(reason:)`
    /// path the rest of the verification UX already handles. Recovery-
    /// key fallback lands with Task 11.
    @ViewBuilder
    private func verifyDeviceSheet(for session: UserSession) -> some View {
        let svc = VerificationServiceLive(
            provider: dependencies.clientProvider,
            session: session
        )
        let requestID = session.userID
        let stream = svc.startSAS(withUser: session.userID, deviceID: nil)
        MacSasView(
            viewModel: SasViewModel(
                stream: stream,
                requestID: requestID,
                confirm: { try await svc.confirmEmojiMatch(requestID: requestID) },
                cancel: { reason in try await svc.cancel(requestID: requestID, reason: reason) }
            ),
            title: "Verify this device",
            onFinished: { showVerifyDeviceSheet = false }
        )
    }

    /// Help → Show Recovery Key… sheet body. Task 11 swap: presents
    /// `MacDeviceSettingsView` (Settings → Device on iOS) so the user
    /// can read their locally-stored recovery key without leaving the
    /// menu route. The .restore-mode `MacRecoveryKeyView` that this
    /// menu used to open lives behind the verification gate /
    /// `MacPostLoginVerificationView` for additional-device installs;
    /// the Help menu's job is reveal-the-existing-key, which is what
    /// Task 11's view does.
    @ViewBuilder
    private func showRecoveryKeySheetBody(for session: UserSession) -> some View {
        let mgr = RecoveryKeyManager(
            provider: dependencies.clientProvider,
            session: session,
            keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true)
        )
        MacDeviceSettingsView(
            session: session,
            verificationService: VerificationServiceLive(
                provider: dependencies.clientProvider,
                session: session
            ),
            currentRecoveryKey: { try mgr.currentKey() },
            onFinished: { showRecoveryKeySheet = false }
        )
    }
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).

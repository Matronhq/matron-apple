import SwiftUI
import MatronAuth
import MatronDesignSystem
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
    /// Persistent `VerificationCenter` for the active session. B2/M5
    /// expert-QA fix mirroring iOS `MatronApp.verificationCenter` —
    /// previously a `let` inside body that was rebuilt on every
    /// `@State` mutation (`bootstrapDone`, `bootstrapError`, `session`,
    /// `verifyDone`, the Help-menu sheet flags). The orphaned center's
    /// `start()` task kept running while the new center was never
    /// started, so the sidebar banner went silent and any sheet built
    /// from the orphaned center hit an empty FlowStore. Hoisted to
    /// `@State` and built from a `.task(id: session.userID)` so the
    /// instance is stable across body re-runs.
    @State private var verificationCenter: VerificationCenter?
    /// Set by `bootstrap()` when the setup-time `KeychainProbe.run(...)`
    /// fails (Phase 3 / Task 13). When non-nil, every other UI branch is
    /// short-circuited and `KeychainSetupErrorView` renders the message.
    /// The recovery-key flow is unusable without working Keychain access,
    /// so this is intentionally a hard gate rather than a dismissable
    /// banner — surfacing the error in onboarding is the regression guard
    /// against shipping a Mac build with broken entitlements.
    @State private var bootstrapError: String?
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
                } else if let bootstrapError {
                    // Hard gate: Keychain probe failed (entitlements
                    // misconfigured). Recovery-key persistence is unusable;
                    // do not let the user reach the sign-in or recovery-key
                    // flows where they'd silently lose their key. See
                    // `bootstrapError`'s declaration for full rationale.
                    // Cross-platform view lives in MatronDesignSystem now
                    // (Phase 3 / Wave 3 / M1) so iOS bootstrap can mount
                    // the same hard gate.
                    KeychainSetupErrorView(message: bootstrapError)
                } else if let session {
                    if verifyDone {
                        // VerificationCenter is hoisted to `@State` and
                        // built inside the `.task(id: session.userID)`
                        // below — see the property's declaration for the
                        // B2/M5 rationale. Optional `verificationCenter`
                        // is nil during the very first body render; the
                        // sidebar banner short-circuits on nil until the
                        // task installs the real instance (then SwiftUI
                        // re-renders).
                        MacChatListView(
                            viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                            verificationCenter: verificationCenter
                        )
                        .frame(minWidth: 800, minHeight: 600)
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        .task { try? await dependencies.syncService(for: session).start() }
                        // See iOS `MatronApp` for full rationale —
                        // VerificationServiceLive.start() registers the
                        // SDK delegate that drives `incomingRequests()` +
                        // every `.readyForEmoji([…])` / `.verified` /
                        // `.cancelled` SAS transition. Without it, the
                        // sidebar banner is silent and every SAS sheet
                        // hangs forever (expert-QA finding B1).
                        .task { try? await dependencies.verificationService(for: session).start() }
                        // B2/M5: build the VerificationCenter exactly
                        // once per session. Keying on `session.userID`
                        // means the task only re-fires on a user switch
                        // (sign-out + back-in), not on the assorted
                        // `@State` mutations the Mac host carries —
                        // `verifyDone`, `bootstrapError`,
                        // `showVerifyDeviceSheet`, `showRecoveryKeySheet`.
                        .task(id: session.userID) {
                            let center = VerificationCenter(
                                service: dependencies.verificationService(for: session)
                            )
                            center.start()
                            verificationCenter = center
                        }
                        .onDisappear {
                            verificationCenter?.stop()
                            verificationCenter = nil
                        }
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
                        // Mirrors the post-verify branch — see iOS
                        // `MatronApp` for full rationale (expert-QA B1).
                        .task { try? await dependencies.verificationService(for: session).start() }
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
        // Phase 3 / Task 13: setup-time Keychain probe. The recovery-key
        // flow writes to a synchronizable `KeychainStore(service:
        // "chat.matron.recovery", synchronizable: true)`; if the bundle's
        // `keychain-access-groups` entitlement is missing or misconfigured,
        // `SecItemAdd` returns `errSecMissingEntitlement` and the user
        // never realises persistence silently failed. Probe early and
        // surface a hard error in the UI before the user can sign in.
        //
        // Wrapped in a 2s timeout so a hypothetical Keychain unlock prompt
        // (or system Keychain stall) doesn't leave the app on the
        // indefinite ProgressView. Plain `Task.sleep` race against the
        // probe via `withThrowingTaskGroup` — first-finish-wins.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Centralised factory — same service the recovery-key
                    // flow writes to. Wave 5 reverted the explicit
                    // `accessGroup:` half (the `$(AppIdentifierPrefix)…`
                    // literal was bug #3 — see `KeychainStore.recoveryStore()`
                    // for the full rationale).
                    try KeychainProbe.run(keychain: KeychainStore.recoveryStore())
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    throw KeychainProbeTimeout()
                }
                // First task to finish wins — cancel the loser. If the
                // probe finished it returns; if the timeout finished it
                // throws and the catch below fires.
                try await group.next()
                group.cancelAll()
            }
        } catch let error as KeychainProbeError {
            bootstrapError = error.localizedDescription
            bootstrapDone = true
            return
        } catch is KeychainProbeTimeout {
            bootstrapError = "Keychain access timed out — see docs/setup-mac.md"
            bootstrapDone = true
            return
        } catch {
            bootstrapError = "Keychain probe failed: \(error.localizedDescription) — see docs/setup-mac.md"
            bootstrapDone = true
            return
        }

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

    /// Help → Verify This Device… sheet body. Hands construction to a
    /// dedicated `HelpMenuVerifyDeviceSheet` whose `@State`-stored
    /// SasViewModel + stream survive the host's body re-renders
    /// (B2/M5 expert-QA fix — the prior inline construction here
    /// rebuilt the VM on every `@State` mutation in `MatronMacApp`).
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
        HelpMenuVerifyDeviceSheet(
            // Cached service so the FlowStore + registered SDK delegate are
            // shared with the sidebar banner / Settings / per-bot banner. A
            // fresh instance would have an empty FlowStore + an unregistered
            // delegate so the SAS sheet would hang forever (expert-QA B1).
            service: dependencies.verificationService(for: session),
            userID: session.userID,
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
            // Centralised factory — service + synchronizable flag stay
            // in lockstep across every recovery-key construction site.
            // See `KeychainStore.recoveryStore()` for the Wave 5 revert
            // rationale (no explicit `accessGroup`; the system falls back
            // to the first `keychain-access-groups` entry, which is ours).
            keychain: KeychainStore.recoveryStore()
        )
        MacDeviceSettingsView(
            session: session,
            // Cached service — Settings → Encryption reads
            // `isThisDeviceVerified()`; sharing the cache means the read
            // doesn't double-fetch the SDK controller (and the registered
            // delegate stays singular).
            verificationService: dependencies.verificationService(for: session),
            currentRecoveryKey: { try mgr.currentKey() },
            onFinished: { showRecoveryKeySheet = false }
        )
    }
}

/// Sentinel error thrown by the timeout branch of `bootstrap()`'s
/// Keychain probe race (Phase 3 / Task 13). Distinct from
/// `KeychainProbeError.getFailed` so the catch arms can render a
/// timeout-specific message without conflating it with an entitlement
/// failure.
private struct KeychainProbeTimeout: Error {}

/// Help → Verify This Device sheet body. Mirrors
/// `MacSelfVerifySasDestination` / `MacVerifyBotSheet` — see iOS
/// `ChatView.swift`'s `VerifyBotSheet` for the Wave 5 bugbot #2
/// rationale (the prior `init`-side `startSAS` call fired on every
/// parent body re-render and silently cancelled the active continuation
/// via Wave 2 / M3's "Replaced by new flow" drain).
private struct HelpMenuVerifyDeviceSheet: View {
    let service: VerificationService
    let userID: String
    let onFinished: () -> Void

    @State private var viewModel: SasViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                MacSasView(
                    viewModel: vm,
                    title: "Verify this device",
                    onFinished: onFinished
                )
            } else {
                ProgressView("Starting verification…")
            }
        }
        .task(id: userID) {
            guard viewModel == nil else { return }
            let stream = service.startSAS(withUser: userID, deviceID: nil)
            viewModel = SasViewModel(
                stream: stream,
                requestID: userID,
                confirm: { try await service.confirmEmojiMatch(requestID: userID) },
                cancel: { reason in try await service.cancel(requestID: userID, reason: reason) }
            )
        }
    }
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).

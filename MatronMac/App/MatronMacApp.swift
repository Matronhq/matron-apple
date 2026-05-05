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
    /// Re-evaluation token bumped when `showVerifyDeviceSheet` flips
    /// from `true` back to `false` (i.e. the Help → Verify This Device
    /// sheet was dismissed). Passed into `MacChatListView` and used as
    /// the `.task(id:)` key for the per-this-device verification check
    /// so a successful self-verify clears the in-list
    /// `MacUnverifiedDeviceBanner` without requiring a chat-list
    /// re-mount. Wave 6 / live-test #3.
    @State private var verifyDeviceDismissToken = 0

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
                        //
                        // Sign-Out / Verify-Device / Show-Recovery-Key
                        // closures (Wave 6 / live-test #1 + #2). Listeners
                        // moved INTO `MacChatListView` because the prior
                        // WindowGroup-root `.onReceive(...)` on a
                        // type-switching `Group { … }` silently dropped
                        // notifications on macOS — so the menu items
                        // posted to the bus but nothing observed them.
                        // Anchoring listeners on this signed-in branch
                        // view is the reliable shape; the host still
                        // owns the side effects via these closures.
                        MacChatListView(
                            viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                            verificationCenter: verificationCenter,
                            onSignOut: { signOut(activeSession: session) },
                            onVerifyDevice: { showVerifyDeviceSheet = true },
                            onShowRecoveryKey: { showRecoveryKeySheet = true },
                            verificationService: dependencies.verificationService(for: session),
                            verifyDeviceDismissToken: verifyDeviceDismissToken
                        )
                        .frame(minWidth: 800, minHeight: 600)
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        .task { try? await dependencies.syncService(for: session).start() }
                        // Wave 7 bug #1+#7: dropped the eager
                        // `verificationService(for: session).start()`
                        // call. The service now subscribes to
                        // `client.encryption().verificationStateListener(...)`
                        // in its `init` and builds the SDK controller
                        // lazily once the listener fires
                        // `!= .unknown`. See iOS `MatronApp` for full
                        // rationale — same pattern, mirrors Element X's
                        // `ClientProxy.updateVerificationState` →
                        // `buildSessionVerificationControllerProxyIfPossible`.
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
                        // Wave 7 bug #1+#7: dropped the eager
                        // `verificationService(for: session).start()`
                        // call. See the post-verify branch above for
                        // full rationale.
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
            // Wave 6 / live-test #1 + #2: the `.signOut`, `.verifyDevice`,
            // and `.showRecoveryKey` `.onReceive` listeners used to live
            // here on the WindowGroup root. macOS SwiftUI did not
            // reliably re-install subscriptions on the Group's
            // type-switching content (sign-in → verify-gate → chat-list),
            // so the menu items silently posted into the void any time
            // the user reached the chat list. Listeners now live INSIDE
            // `MacChatListView` (the signed-in branch view); the host
            // exposes the side-effect mutators via closures passed into
            // that view (`onSignOut`, `onVerifyDevice`, `onShowRecoveryKey`).
            // The host still owns the sheet presentation flags
            // (`showVerifyDeviceSheet` / `showRecoveryKeySheet`) since
            // the sheets need session + dependencies that the host
            // already holds — closure-flips toggle them.
            .sheet(isPresented: $showVerifyDeviceSheet) {
                if let session {
                    verifyDeviceSheet(for: session)
                } else {
                    Text("Sign in first to verify this device.")
                        .frame(width: 360, height: 120)
                        .padding()
                }
            }
            // Bump the re-eval token whenever the verify-device sheet
            // closes so `MacChatListView`'s `.task(id: verifyDeviceDismissToken)`
            // re-runs `isThisDeviceVerified()`. A successful self-verify
            // clears the in-list `MacUnverifiedDeviceBanner` without
            // requiring a chat-list re-mount. Wave 6 / live-test #3.
            .onChange(of: showVerifyDeviceSheet) { _, isPresented in
                if !isPresented { verifyDeviceDismissToken &+= 1 }
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
        // Wire matrix-rust-sdk tracing FIRST — initPlatform must run
        // exactly once per process AND before the first ClientBuilder()
        // is instantiated. Without this the SDK is silent (no /sync, no
        // /keys/query, no enableRecovery, no verification internals
        // logged), which is what stranded the matron-vs-matron-ui
        // scenario for a full session of debugging — see Phase 3
        // session 4 in `docs/HANDOVER.md`.
        MatronSDKTracing.setup()

        // Phase 3 / Task 13: setup-time Keychain probe. The recovery-key
        // flow writes to a synchronizable `KeychainStore(service:
        // "chat.matron.recovery", synchronizable: true)`; if the bundle's
        // `keychain-access-groups` entitlement is missing or misconfigured,
        // `SecItemAdd` returns `errSecMissingEntitlement` and the user
        // never realises persistence silently failed. Probe early and
        // surface a hard error in the UI before the user can sign in.
        //
        // Skip the probe when the bundle has no `keychain-access-groups`
        // entitlement loaded. Two cases hit this path:
        //  - Unsigned local-dev builds (`xcodebuild ... CODE_SIGNING_ALLOWED=NO`):
        //    the entitlement file declares the group correctly but the
        //    unsigned bundle carries no entitlements at runtime, so every
        //    Keychain op fails with `-34018`. The probe would block local
        //    dev sign-in for no real reason — recovery-key persistence
        //    legitimately won't work on this build, but the failure mode
        //    is well-known and the dev hasn't shipped anything.
        //  - Mac Catalyst / future ad-hoc builds with no entitlements.
        // Production builds (TestFlight / signed Release) retain the
        // entitlement, so the probe still catches genuinely-broken
        // production entitlement plists.
        let hasEntitlement: Bool = {
            guard let task = SecTaskCreateFromSelf(nil) else { return false }
            let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil)
            return value != nil
        }()
        if hasEntitlement {
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
            } catch is CancellationError {
                // Defensive: when the probe wins the race, `group.cancelAll()`
                // cancels the still-pending `Task.sleep` in the timeout child.
                // The cancelled sleep throws `CancellationError`, which the
                // task group's implicit drain on body-return can rethrow out
                // of `withThrowingTaskGroup`. Without this arm the success
                // path would fall into the generic catch below and surface a
                // bogus "Keychain probe failed" error. No-op when the loser's
                // cancellation is silently swallowed (Swift version
                // dependent); critical-fix when it isn't.
                // Probe success has already been observed via `group.next()`,
                // so it's safe to fall through to the post-probe bootstrap.
            } catch {
                bootstrapError = "Keychain probe failed: \(error.localizedDescription) — see docs/setup-mac.md"
                bootstrapDone = true
                return
            }
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

    /// Sign-out side effect, mirroring the iOS host's `signOut()`.
    /// Wave 6 / live-test #1: extracted from the prior WindowGroup-root
    /// `.onReceive(.signOut)` body so `MacChatListView`'s `onSignOut`
    /// closure can call it. Clears the persisted verify-done flag for
    /// the active session (so a deliberate sign-out + back-in re-runs
    /// the verification gate), drops `AppDependencies` caches, and
    /// flips `session = nil` so the WindowGroup re-mounts the
    /// `MacSignInView` branch.
    private func signOut(activeSession: UserSession) {
        UserDefaults.standard.removeObject(
            forKey: MacPostLoginVerificationView.verifyDoneKey(for: activeSession)
        )
        dependencies.signOut()
        session = nil
        verifyDone = false
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
            recoveryKeyRestore: { key in
                let mgr = RecoveryKeyManager(
                    provider: dependencies.clientProvider,
                    session: session,
                    keychain: KeychainStore.recoveryStore()
                )
                try await mgr.restore(usingKey: key)
            },
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
    /// Closure that runs `RecoveryKeyManager.restore(usingKey:)` against
    /// the host's session — the sheet itself doesn't construct a
    /// manager so it stays free of `RecoveryKeyManager` /
    /// `KeychainStore` dependencies; the caller wires the right
    /// instance based on the active session.
    let recoveryKeyRestore: (String) async throws -> Void
    let onFinished: () -> Void

    /// Sheet phase. `.probing` while we check `isThisDeviceVerified()`.
    /// `.alreadyVerified` short-circuits the chooser when there's
    /// nothing to do. `.chooser` renders the two-button picker —
    /// without it, the only path the chat-list `MacUnverifiedDeviceBanner`
    /// surfaced was SAS, which strands users when no other verified
    /// device is online (e.g. both devices' SDK stores got wiped on
    /// re-login). `.sas` and `.recoveryKey` are the post-pick states.
    enum Phase {
        case probing, alreadyVerified, chooser, sas, recoveryKey
    }
    @State private var phase: Phase = .probing
    @State private var sasViewModel: SasViewModel?
    @State private var recoveryKeyViewModel: RecoveryKeyViewModel?
    /// `nil` while the probe is in flight; `true` if the SDK reports
    /// at least one other already-verified device of the same user
    /// (`Encryption.hasDevicesToVerifyAgainst()`); `false` if there's
    /// nothing online to SAS-verify against. Drives the disabled
    /// state on the "Verify with another device" button — without
    /// this, users with no other verified peer get stranded waiting
    /// on a SAS that can never complete.
    @State private var hasOtherDevices: Bool? = nil

    var body: some View {
        Group {
            switch phase {
            case .probing:
                ProgressView("Loading…")
                    .frame(width: 480, height: 320)
            case .alreadyVerified:
                alreadyVerifiedView
            case .chooser:
                chooserView
            case .sas:
                if let vm = sasViewModel {
                    MacSasView(
                        viewModel: vm,
                        title: "Verify this device",
                        onFinished: onFinished,
                        onCancelled: onFinished
                    )
                } else {
                    ProgressView("Starting verification…")
                }
            case .recoveryKey:
                if let vm = recoveryKeyViewModel {
                    MacRecoveryKeyView(
                        viewModel: vm,
                        onFinished: onFinished
                    )
                } else {
                    ProgressView("Loading…")
                }
            }
        }
        .task(id: userID) {
            guard phase == .probing else { return }
            let verified = (try? await service.isThisDeviceVerified()) ?? false
            if verified {
                phase = .alreadyVerified
                return
            }
            // Probe before the chooser renders so the "Verify with
            // another device" button's disabled state is settled
            // before the user sees it (avoids a flash of "enabled →
            // disabled" if the SDK is slow).
            hasOtherDevices = (try? await service.hasOtherVerifiedDevices()) ?? false
            phase = .chooser
        }
    }

    private var alreadyVerifiedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("This device is already verified")
                .font(.title2).bold()
            Text("If you want to verify a different device, sign in there and start the verification from that device's onboarding gate.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Close") { onFinished() }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 480, height: 320)
    }

    private var chooserView: some View {
        // View body extracted to `MacVerifyDeviceChooser` so the disabled-
        // when-no-other-devices branch can be snapshot-tested in isolation.
        // This sheet still owns the post-pick state mutations
        // (constructing SasViewModel / RecoveryKeyViewModel and flipping
        // `phase`); the chooser just dispatches the user's choice.
        MacVerifyDeviceChooser(
            hasOtherDevices: hasOtherDevices ?? false,
            onSAS: {
                let stream = service.startSAS(withUser: userID, deviceID: nil)
                sasViewModel = SasViewModel(
                    stream: stream,
                    requestID: userID,
                    confirm: { try await service.confirmEmojiMatch(requestID: userID) },
                    cancel: { reason in try await service.cancel(requestID: userID, reason: reason) }
                )
                phase = .sas
            },
            onRecoveryKey: {
                recoveryKeyViewModel = RecoveryKeyViewModel(
                    mode: .restore,
                    generate: { "" },
                    restore: recoveryKeyRestore
                )
                phase = .recoveryKey
            },
            onClose: { onFinished() }
        )
    }
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).

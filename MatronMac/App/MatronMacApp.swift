import SwiftUI
import MatronAuth
import MatronDesignSystem
import MatronModels
import MatronPush
import MatronStorage
import MatronVerification
import MatronViewModels

@main
struct MatronMacApp: App {
    /// Phase 4 Tasks 10/11 — APNs token capture + UN center delegate
    /// installation. The adaptor keeps a single delegate instance
    /// alive for the process lifetime; `applicationDidFinishLaunching`
    /// installs the shared `MacNotificationHandler` as the
    /// `UNUserNotificationCenter` delegate so taps surface from launch.
    @NSApplicationDelegateAdaptor(MatronMacAppDelegate.self) private var appDelegate

    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// Mac mirror of `MatronApp.verifyDone` — onboarding step-2 gate.
    /// Per-user `UserDefaults` scoping lives in `UserSession.verifyDoneKey`.
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
                            // If `session.userID` flips while the verifyDone branch stays
                            // mounted (multi-account switch), `.onDisappear` won't fire —
                            // stop the prior center explicitly so its long-lived
                            // `incomingRequests()` stream doesn't outlive its session.
                            if let prior = verificationCenter {
                                prior.stop()
                                verificationCenter = nil
                            }
                            let center = VerificationCenter(
                                service: dependencies.verificationService(for: session)
                            )
                            center.start()
                            verificationCenter = center
                        }
                        // Phase 4 Task 11: request push permission, set
                        // every joined room to `.allMessages`, register
                        // for remote notifications, and plumb the APNs
                        // token to the homeserver pusher record. Mirrors
                        // the iOS `MatronApp.bootstrapPush(for:)` flow,
                        // bar the platform-specific
                        // `NSApplication.shared.registerForRemoteNotifications()`
                        // path inside the shared `PushBootstrap`. Keyed on
                        // `session.userID` so a multi-account switch
                        // re-runs against the new user's pusher row.
                        .task(id: session.userID) {
                            await bootstrapPush(for: session)
                        }
                        // Phase 6 (Search): sweep room history into the FTS
                        // index once per session — mirrors the iOS host.
                        .task(id: session.userID) {
                            guard let coordinator = dependencies.backfillCoordinator(for: session) else { return }
                            let roomIDs = await dependencies.chatService(for: session).firstSnapshotRoomIDs()
                            await coordinator.run(roomIDs: roomIDs)
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
                                forKey: session.verifyDoneKey
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
            // Tracked across `do`/`catch` so the `CancellationError` arm can
            // distinguish race-loser drain from a real external cancellation.
            // See the catch arm below for the full rationale.
            var probeSucceeded = false
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
                    probeSucceeded = true
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
                // Two sources can throw `CancellationError` here: (a) the loser
                // of the race (the timeout's `Task.sleep` cancelled by
                // `group.cancelAll()` once the probe returned) — its drain on
                // body-return rethrows out of `withThrowingTaskGroup`; (b) the
                // bootstrap task itself being cancelled externally before the
                // probe completes. Only (a) is safe to swallow — `probeSucceeded`
                // distinguishes the two so we don't silently mark bootstrap
                // done on a real external cancel and let the user into flows
                // with broken Keychain access.
                if !probeSucceeded {
                    bootstrapDone = true
                    return
                }
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
                    forKey: session.verifyDoneKey
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
        UserDefaults.standard.set(true, forKey: session.verifyDoneKey)
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
        // Phase 4 Task 8: best-effort pusher unregister BEFORE clearing
        // the session. Enqueued through the shared `pushOperationTail`
        // chain on PushTokenStore so a fast sign-out → sign-in cycle's
        // unregister can't land AFTER the new session's register and
        // delete the freshly-written pusher row (cursor PR #5 finding).
        // Mirrors the iOS host's signOut path.
        if let token = PushTokenStore.shared.cachedToken {
            let provider = dependencies.clientProvider
            let pusherURL = Self.pusherBaseURL
            PushTokenStore.shared.enqueuePushOperation {
                let pushService = PushServiceLive(provider: provider, session: activeSession)
                try? await pushService.unregister(
                    deviceToken: token,
                    pusherBaseURL: pusherURL
                )
            }
        }
        UserDefaults.standard.removeObject(
            forKey: activeSession.verifyDoneKey
        )
        dependencies.signOut()
        session = nil
        verifyDone = false
        // Drop any buffered cold-start tap so the next sign-in's
        // `MacChatListView.task` doesn't drain a stale room ID from
        // the prior account (cursor PR #5 third-pass finding "Mac
        // cold-start taps are dropped" plus the stale-pending
        // hygiene that the iOS host already does on `signOut`).
        MacNotificationHandler.shared.clearPendingRoomID()
    }

    /// Phase 4 Task 11 — full push pipeline bootstrap for `session`,
    /// Mac variant. The flow lives in `PushBootstrap.bootstrapHost`
    /// (shared with the iOS host — the two copies were byte-identical,
    /// cursor PR #5 fourth-pass finding). What stays Mac-specific is
    /// `NotificationProcessSetup`: Mac handles pushes in-process
    /// (no NSE) so the `PushDecoder.live` factory will eventually need
    /// `.singleProcess(syncService: SyncService)` for the silent-push
    /// decode path (deferred — see `MacNotificationHandler`'s
    /// doc-comment). The bootstrap itself only needs
    /// `Client.setPusher(...)`, which is platform-agnostic.
    @MainActor
    private func bootstrapPush(for session: UserSession) async {
        let chat = dependencies.chatService(for: session)
        await PushBootstrap.bootstrapHost(
            provider: dependencies.clientProvider,
            session: session,
            pusherBaseURL: Self.pusherBaseURL,
            joinedRoomIDs: { await chat.firstSnapshotRoomIDs() }
        )
    }

    /// Sygnal pusher endpoint URL — see iOS host's `pusherBaseURL`
    /// doc-comment for the full "what the URL means + what's still
    /// needed for end-to-end delivery" rationale. Mac and iOS share
    /// the same Sygnal hostname (Sygnal differentiates per-platform
    /// via `app_id` on the pusher record, not via URL).
    private static let pusherBaseURL = URL(
        string: "https://sygnal.matron.chat/_matrix/push/v1/notify"
    )!

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

/// Help → Verify This Device sheet body. Owns the probing /
/// alreadyVerified / chooser / recoveryKey phase machine; the SAS
/// sub-flow itself is delegated to `MacSasSheetWrapper`. See
/// `SasSheetWrapper.swift` for the Wave 5 bugbot #2 rationale (the
/// prior `init`-side `startSAS` call fired on every parent body
/// re-render and silently cancelled the active continuation via Wave 2 /
/// M3's "Replaced by new flow" drain).
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
                // SAS sub-flow delegated to `MacSasSheetWrapper` (PR #3
                // review #1). The phase state machine (chooser /
                // recovery-key / probing / alreadyVerified) stays here;
                // only the SAS surface is the wrapped pattern.
                MacSasSheetWrapper(
                    service: service,
                    requestID: userID,
                    title: "Verify this device",
                    streamFactory: { $0.startSAS(withUser: userID, deviceID: nil) },
                    onFinished: onFinished,
                    onCancelled: onFinished
                )
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
            // Tri-state probe: only short-circuit on an explicit `true`.
            // `nil` (unknown / SDK still loading the identity) falls
            // through to the chooser; collapsing it into `false` would
            // make the chooser flash before the SDK has populated state.
            let verified = try? await service.isThisDeviceVerified()
            if verified == true {
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
        // Cross-signing-verified ≠ backup-key-available. Post-SAS the
        // backup decryption key arrives via secret gossiping, but if
        // the partner device didn't have it, or sliding sync dropped
        // before the to-device event landed, this device shows as
        // verified but historical messages still render as
        // [unsupported event: m.room.encrypted] — the SDK has no key
        // to decrypt the backup. Offer the recovery-key restore here
        // so the user has a path out without re-doing SAS.
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 60))
                .foregroundStyle(.green)
            Text("This device is already verified")
                .font(.title2).bold()
            Text("If your historical messages aren't decrypting, restoring from your recovery key fetches the backup decryption key for this device.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Restore from recovery key…") {
                    recoveryKeyViewModel = .restoring(restore: recoveryKeyRestore)
                    phase = .recoveryKey
                }
                Button("Close") { onFinished() }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 480, height: 320)
    }

    private var chooserView: some View {
        // View body extracted to `MacVerifyDeviceChooser` so the disabled-
        // when-no-other-devices branch can be snapshot-tested in isolation.
        // SAS construction is delegated to `MacSasSheetWrapper`'s
        // `.task(id:)`; this sheet still owns the recovery-key VM and
        // flips `phase`; the chooser just dispatches the user's choice.
        MacVerifyDeviceChooser(
            hasOtherDevices: hasOtherDevices ?? false,
            onSAS: {
                // The wrapper now owns SAS VM construction; just flip
                // the phase. `MacSasSheetWrapper.task(id:)` opens the
                // stream once on entry into `.sas`.
                phase = .sas
            },
            onRecoveryKey: {
                recoveryKeyViewModel = .restoring(restore: recoveryKeyRestore)
                phase = .recoveryKey
            },
            onClose: { onFinished() }
        )
    }
}

// UNUserNotificationCenter.current().delegate registration is deferred
// to Phase 4 (Push & NSE).

import SwiftUI
import MatronAuth
import MatronDesignSystem
import MatronModels
import MatronPush
import MatronStorage
import MatronVerification
import MatronViewModels

@main
struct MatronApp: App {
    /// Phase 4 Task 5 — APNs token capture lives on the
    /// `UIApplicationDelegate`, not on the SwiftUI scene. The adaptor
    /// keeps a single delegate instance alive for the process lifetime
    /// so the system can hand `didRegisterForRemoteNotificationsWithDeviceToken`
    /// back to the same object every push registration cycle. The
    /// delegate forwards tokens into `PushTokenStore.shared` which
    /// the `.task` on the post-verify branch awaits via
    /// `PushBootstrap.bootstrap()` + `register(token:)`.
    @UIApplicationDelegateAdaptor(MatronAppDelegate.self) private var appDelegate

    @State private var dependencies = AppDependencies()
    @State private var session: UserSession?
    @State private var bootstrapDone = false
    /// Onboarding step-2 gate (Phase 3 / spec §5.2). Sign-in lands the user
    /// in this view-model; once `verifyDone` flips true (either after a
    /// successful verification flow or because the persisted flag was
    /// already set on relaunch), the chat list becomes reachable. Per-user
    /// `UserDefaults` scoping via `UserSession.verifyDoneKey`.
    @State private var verifyDone = false
    /// Persistent `VerificationCenter` for the active session. B2/M5
    /// expert-QA fix: previously this was constructed inline as a
    /// `let verificationCenter = VerificationCenter(...)` inside body.
    /// Every `@State` mutation in the host (`bootstrapDone`, `session`,
    /// `verifyDone`, etc.) re-runs `body`, producing a NEW center each
    /// time. The old center's `start()` task kept running on the stale
    /// instance (orphaned), and the new center's `start()` was never
    /// invoked because `ChatListView.onAppear` is per-view-identity, not
    /// per-render. The chat-list banner went dark and any SAS sheet built
    /// from the orphaned center hit an empty FlowStore.
    ///
    /// Hoisting to `@State` + driving construction from a `.task(id:)`
    /// keeps the center stable across body re-evaluations and (correctly)
    /// rebuilds when the user changes.
    @State private var verificationCenter: VerificationCenter?
    /// Phase 4 Task 6 — chat-list `NavigationStack` path. Hoisted to
    /// the host so a notification tap (routed via
    /// `NotificationDelegate.shared.tappedRoomID`) can append a room
    /// ID and SwiftUI's stack drives the existing
    /// `ChatListView.navigationDestination(for: ChatSummary.ID.self)`
    /// branch. `[String]` because `ChatSummary.ID == String`.
    @State private var chatPath: [String] = []
    /// Set by `bootstrap()` when the setup-time `KeychainProbe.run(...)`
    /// fails (Phase 3 / Wave 3 / M1 — parity with Mac Task 13). When
    /// non-nil, every other UI branch is short-circuited and
    /// `KeychainSetupErrorView` renders the message. The recovery-key
    /// flow is unusable without working Keychain access, so this is
    /// intentionally a hard gate rather than a dismissable banner —
    /// surfacing the error in onboarding is the regression guard against
    /// shipping an iOS build with broken `keychain-access-groups`
    /// entitlements (e.g. signing-team mismatch on a TestFlight build).
    /// Stays `nil` on the iOS Simulator: the probe is `#if
    /// !targetEnvironment(simulator)`-gated because the Sim can't resolve
    /// `$(AppIdentifierPrefix)` without a signing team.
    @State private var bootstrapError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if !bootstrapDone {
                    ProgressView("Loading…")
                        .task { await bootstrap() }
                } else if let bootstrapError {
                    // Hard gate: Keychain probe failed (entitlements
                    // misconfigured). Recovery-key persistence is unusable;
                    // do not let the user reach the sign-in or recovery-key
                    // flows where they'd silently lose their key. See
                    // `bootstrapError`'s declaration for full rationale.
                    // Phase 3 / Wave 3 / M1 — parity with Mac Task 13.
                    KeychainSetupErrorView(message: bootstrapError)
                } else if let session {
                    if verifyDone {
                        // VerificationCenter is hoisted to `@State` and
                        // built inside the `.task(id: session.userID)`
                        // below — see the property's declaration for the
                        // B2/M5 rationale. Passing the optional through
                        // is safe: `ChatListView.verificationCenter` is
                        // already an `Optional<VerificationCenter>` and
                        // its banner code short-circuits on `nil` until
                        // the task installs the real instance.
                        NavigationStack(path: $chatPath) {
                            ChatListView(
                                viewModel: ChatListViewModel(chat: dependencies.chatService(for: session)),
                                onSignOut: { signOut() },
                                // Phase 6 (Search): a search result navigates by
                                // appending the room ID onto the stack path the
                                // host owns (same mechanism as a notification tap).
                                onOpenChat: { roomID in
                                    if chatPath.last != roomID { chatPath.append(roomID) }
                                },
                                verificationCenter: verificationCenter
                            )
                        }
                        .environment(\.appDependencies, dependencies)
                        .environment(\.currentSession, session)
                        // Phase 4 Task 6: notification-tap deep link.
                        // The NSE-rewritten userInfo carries `room_id`;
                        // NotificationDelegate publishes that ID and we
                        // append it onto the navigation path so the
                        // existing `navigationDestination(for: ChatSummary.ID.self)`
                        // branch in ChatListView pushes the chat. Idempotent
                        // on duplicate sends (re-appending a room already
                        // at the top of the stack just no-ops the user
                        // visually); cleared on sign-out via `signOut()`
                        // below so a tap from the previous session can't
                        // strand the new user inside a stale room.
                        .onReceive(NotificationDelegate.shared.tappedRoomID) { roomID in
                            if chatPath.last != roomID {
                                chatPath.append(roomID)
                            }
                        }
                        .task { try? await dependencies.syncService(for: session).start() }
                        // Wave 7 bug #1+#7: dropped the eager
                        // `verificationService(for: session).start()`
                        // call here. The service now subscribes to
                        // `client.encryption().verificationStateListener(...)`
                        // in its `init`; the SDK controller is built
                        // lazily the first time the listener fires
                        // `!= .unknown` (i.e. after `/keys/query` lands).
                        // The eager call would race the listener and
                        // hang for 7+ seconds against an empty key
                        // store (live debugging confirmed). Mirrors
                        // Element X's `ClientProxy.updateVerificationState`
                        // → `buildSessionVerificationControllerProxyIfPossible`
                        // pattern (see
                        // `ElementX/Sources/Services/Client/ClientProxy.swift`).
                        // B2/M5: build the VerificationCenter exactly once
                        // per session and call `start()` on the same
                        // instance that's handed to ChatListView. Keying
                        // on `session.userID` means the task only re-fires
                        // on a user switch (sign-out + back-in), not on
                        // unrelated `@State` mutations like `verifyDone`
                        // or `bootstrapDone` flipping. Stop is wired in
                        // `.onDisappear` below so the long-lived
                        // `incomingRequests()` stream doesn't outlive the
                        // verifyDone branch.
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
                        // Phase 4 Task 5: request push permission, set
                        // every joined room to `.allMessages`, register
                        // for remote notifications, and plumb the APNs
                        // token to the homeserver pusher record. Keyed on
                        // `session.userID` so a multi-account switch
                        // re-runs the bootstrap against the new user's
                        // pusher row. The task body completes once the
                        // token is registered (or the user denies
                        // permission); SwiftUI keeps the Task struct
                        // around until the view dies.
                        .task(id: session.userID) {
                            // Cold-start tap drain (cursor PR #5
                            // finding): if iOS launched the app
                            // specifically because the user tapped a
                            // notification on the lock screen,
                            // `didReceive` ran before the
                            // `.onReceive(tappedRoomID)` below
                            // subscribed and `PassthroughSubject`
                            // dropped the value. The delegate buffers
                            // such taps in `pendingRoomID`; drain it
                            // here.
                            if let pending = NotificationDelegate.shared.consumePendingRoomID(),
                               chatPath.last != pending {
                                chatPath.append(pending)
                            }
                            await bootstrapPush(for: session)
                        }
                        // Phase 6 (Search): sweep room history into the FTS
                        // index once per session. Waits for the first chat-list
                        // snapshot so rooms are known, then backfills serially.
                        // Resume-guarded (BackfillRunner skips completed rooms),
                        // so a relaunch just re-checks each room cheaply.
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
                        // Wave 7 bug #1+#7: dropped the eager
                        // `verificationService(for: session).start()`
                        // call. See the post-verify branch above for
                        // the full rationale — the service now
                        // initialises reactively via the SDK's
                        // verification-state listener.
                    }
                } else {
                    SignInView(
                        viewModel: SignInViewModel(auth: dependencies.auth, deviceDisplayName: "Matron iOS"),
                        onSignedIn: { session in
                            self.session = session
                            // Restore any prior verifyDone state for this
                            // user so a re-sign-in doesn't re-prompt them.
                            self.verifyDone = UserDefaults.standard.bool(
                                forKey: session.verifyDoneKey
                            )
                        }
                    )
                }
            }
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

        // Phase 3 / Wave 3 / M1: setup-time Keychain probe (parity with
        // Mac Task 13). Skipped on the iOS Simulator because
        // `$(AppIdentifierPrefix)` doesn't resolve without a signing team
        // — the Sim build has the entitlement *string* but
        // `SecItemAdd`/`SecItemCopyMatching` against an unresolved
        // access-group surfaces `errSecMissingEntitlement (-34018)` on
        // every call. Real-device + signed-CI builds run the probe and
        // surface failure via the hard-gate UI in `body`.
        //
        // `RecoveryKeyManager.generateAndPersist` already catches the
        // post-sign-in case (write failed → return the key anyway with a
        // `PersistenceError.keychainWriteFailedButKeyAvailable`), but
        // that's after the user has signed in + generated a key. The
        // probe catches the misconfiguration BEFORE sign-in so the user
        // doesn't lose their key to a silent persistence failure.
        #if !targetEnvironment(simulator)
        // Tracked across `do`/`catch` so the `CancellationError` arm can
        // distinguish race-loser drain from a real external cancellation.
        // See the catch arm below for the full rationale.
        var probeSucceeded = false
        do {
            // Wrap in a 2s timeout so a hypothetical Keychain unlock
            // prompt (e.g. first-time iCloud Keychain setup) doesn't
            // strand the app on the indefinite ProgressView. Mirrors the
            // Mac probe's `withThrowingTaskGroup` race.
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
                try await group.next()
                probeSucceeded = true
                group.cancelAll()
            }
        } catch let error as KeychainProbeError {
            bootstrapError = error.localizedDescription
            bootstrapDone = true
            return
        } catch is KeychainProbeTimeout {
            bootstrapError = "Keychain access timed out — see docs/setup-ios.md"
            bootstrapDone = true
            return
        } catch is CancellationError {
            // Two sources can throw `CancellationError` here: (a) the loser
            // of the race (the timeout's `Task.sleep` cancelled by
            // `group.cancelAll()` once the probe returned) — its drain on
            // body-return rethrows out of `withThrowingTaskGroup`; (b) the
            // bootstrap task itself being cancelled externally before the
            // probe completes. Only (a) is safe to swallow — `probeSucceeded`
            // distinguishes the two so we don't silently mark bootstrap done
            // on a real external cancel and let the user into flows with
            // broken Keychain access.
            if !probeSucceeded {
                bootstrapDone = true
                return
            }
        } catch {
            bootstrapError = "Keychain probe failed: \(error.localizedDescription) — see docs/setup-ios.md"
            bootstrapDone = true
            return
        }
        #endif

        do {
            session = try await dependencies.auth.restoreSession()
            // Restore the verify-done flag for the bootstrapped session
            // so a relaunch with an existing session lands directly in
            // the chat list rather than the verification gate.
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

    /// Persists the verify-done flag for the active session and flips the
    /// in-memory state so the host swaps from `PostLoginVerificationView`
    /// to the chat list. Per-user scoping lives in the key — multi-account
    /// scenarios won't trample each other's flags.
    private func markVerifyDone(for session: UserSession) {
        UserDefaults.standard.set(true, forKey: session.verifyDoneKey)
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
        // Phase 4 Task 8: best-effort pusher unregister BEFORE clearing
        // the session. Enqueued through the shared `pushOperationTail`
        // chain on PushTokenStore so a fast sign-out → sign-in cycle's
        // unregister can't land AFTER the new session's register and
        // delete the freshly-written pusher row (cursor PR #5 finding).
        // Capture provider + session up front because
        // `dependencies.signOut()` invalidates the ClientProvider
        // immediately below — the chain's work runs later but uses
        // the snapshot.
        if let session, let token = PushTokenStore.shared.cachedToken {
            let provider = dependencies.clientProvider
            let pusherURL = Self.pusherBaseURL
            PushTokenStore.shared.enqueuePushOperation {
                let pushService = PushServiceLive(provider: provider, session: session)
                try? await pushService.unregister(
                    deviceToken: token,
                    pusherBaseURL: pusherURL
                )
            }
        }
        if let session {
            UserDefaults.standard.removeObject(forKey: session.verifyDoneKey)
        }
        dependencies.signOut()
        session = nil
        verifyDone = false
        // Drop any deep-linked room from the prior session so the next
        // sign-in lands at the chat list root, not stranded inside a
        // (now-inaccessible) prior-account room.
        chatPath = []
        // Drop any buffered cold-start tap so the next sign-in's
        // post-verify `.task(id: session.userID)` doesn't drain a
        // stale room ID from the prior account (cursor PR #5
        // second-pass finding "live taps leave stale pending rooms").
        NotificationDelegate.shared.clearPendingRoomID()
    }

    /// Phase 4 Task 5 — full push pipeline bootstrap for `session`.
    /// The flow (permission → per-room mode → waitForToken →
    /// register, with the cancellation and error-swallow semantics)
    /// lives in `PushBootstrap.bootstrapHost` — shared with
    /// `MatronMacApp` since the two copies were byte-identical
    /// (cursor PR #5 fourth-pass finding).
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

    /// Sygnal pusher endpoint URL. **Out of scope for Phase 4 plan**:
    /// Sygnal pusher endpoint — the public HTTPS URL the homeserver
    /// will POST notification payloads to once a pusher record has
    /// been written for this device. The hostname is the planned
    /// production target (`sygnal.matron.chat`, served via Cloudflare
    /// Tunnel from the box that runs `matron-server`); end-to-end
    /// delivery still depends on (a) the Sygnal container being up,
    /// (b) APNs `.p8` auth credentials provisioned in Sygnal's config
    /// for all four `app_id`s, (c) DNS resolving the hostname. Until
    /// (a)–(c) are in place, `bootstrap.register(token:)` writes the
    /// pusher row successfully (the homeserver accepts any URL); the
    /// homeserver then logs DNS-resolution failures when it tries to
    /// deliver. Path suffix `_matrix/push/v1/notify` is the Matrix
    /// spec endpoint Sygnal serves; do NOT change it without
    /// changing Sygnal's listener route too.
    private static let pusherBaseURL = URL(
        string: "https://sygnal.matron.chat/_matrix/push/v1/notify"
    )!
}

/// Sentinel error thrown by the timeout branch of `MatronApp.bootstrap()`'s
/// Keychain probe race (Phase 3 / Wave 3 / M1). Distinct from
/// `KeychainProbeError.getFailed` so the catch arms can render a
/// timeout-specific message without conflating it with an entitlement
/// failure. Mirrors the Mac sentinel of the same name in `MatronMacApp`.
private struct KeychainProbeTimeout: Error {}

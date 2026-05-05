import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync
import os

/// Production implementation of `VerificationService`. Wraps the SDK's session
/// verification surface (`MatrixRustSDK.SessionVerificationController`) behind a
/// per-request controller cache so the UI can drive accept / confirm / cancel
/// against an `AsyncStream<SasFlowState>` without holding raw SDK delegate objects.
///
/// # Wave 7 — Element X-aligned rewrite
///
/// This file was rewritten to mirror the canonical patterns Element X iOS
/// uses against the same SDK (matrix-rust-components-swift v26.04.01). Live
/// integration debugging surfaced six concrete bugs in the prior shape:
///
///   1. Eager `client.getSessionVerificationController()` from a `.task` at
///      sign-in raced ahead of the SDK's first `/keys/query` response, hung
///      for 7+ seconds, then collided with the lazy fetch from `startSAS`.
///   2. Multiple concurrent `start()` callers each fetched their own
///      controller (the `hasSDKController()` idempotency check raced with
///      itself).
///   3. The strong delegate retained the service via `sharedController`,
///      and the SDK retained the delegate — a mild cycle that Element X
///      explicitly works around with a weak wrapper.
///   4. `acceptIncoming` called `startSasVerification()` immediately after
///      `acceptVerificationRequest()`, racing the SDK's internal state
///      transition and tripping MAC mismatches when emojis appeared.
///   5. The `MatronApp` hosts fired two parallel `.task` calls (one for
///      sync, one for verification) where the verification call required
///      sync to have run first.
///
/// Element X's pattern:
///   * Subscribe to `client.encryption().verificationStateListener(listener:)`
///     in `init`. Build the SessionVerificationController exactly once, the
///     first time the listener fires `!= .unknown` (which is the SDK's
///     proxy for "the user identity is loaded — `getSessionVerificationController`
///     will not hang"). Cache it.
///   * Wrap the delegate in a `WeakSessionVerificationControllerProxy` so
///     the SDK's strong retention of the delegate doesn't pin us.
///   * On the responder side: `acceptVerificationRequest()` only. The SDK
///     fires `didAcceptVerificationRequest` when the partner has accepted;
///     the delegate then calls `startSasVerification()`. (See
///     `LiveSessionVerificationDelegate.didAcceptVerificationRequest` for
///     the responder/requester branch.)
///   * On the requester side: `requestDeviceVerification()` /
///     `requestUserVerification()` only. NEVER call `startSasVerification()`
///     (only the responder may, otherwise both sides send
///     `m.key.verification.start` and the SAS MAC fails).
///
/// Element X reference files (read locally, do not WebFetch):
///   * `ElementX/Sources/Services/Client/ClientProxy.swift` —
///     `verificationStateListener` + `buildSessionVerificationControllerProxyIfPossible`.
///   * `ElementX/Sources/Services/SessionVerification/SessionVerificationControllerProxy.swift`
///     — `WeakSessionVerificationControllerProxy` + delegate set in init / nil in deinit.
///   * `ElementX/Sources/Screens/Onboarding/SessionVerificationScreen/SessionVerificationScreenStateMachine.swift`
///     — when `startSasVerification` is fired in the SAS state machine.
///
/// Concurrency model: the per-request `controllers` (controllers) and
/// `continuations` (open SAS streams) are stored on a private `actor` so
/// reads + writes from accept / confirm / cancel are serialised. The class
/// itself is `@unchecked Sendable` because all mutation hops through the actor.
///
/// Test surface: callers can construct `VerificationServiceLive()` with no args
/// for unit tests that exercise the controller-cache flow against
/// `FakeSessionVerificationController`. The SDK-bound surfaces
/// (`isThisDeviceVerified`, `incomingRequests`, `startSAS`) require a live
/// `Client` and throw / return empty when the no-arg init was used; they are
/// integration-tested in Phase 7 against a real homeserver. Tests can also
/// drive the delegate-routed paths via `routeSasStarted()` /
/// `routeSasData(_:)` / `routeSasFinished()` / `routeSasCancelled()` / the
/// new `routeAcceptedVerificationRequest()` directly.
public final class VerificationServiceLive: VerificationService, SessionVerificationFlowRouting, @unchecked Sendable {
    private let provider: ClientProvider?
    private let session: UserSession?

    /// Per-request bookkeeping (controllers + open continuations) lives on its own
    /// actor so the cross-task accept/confirm/cancel mutations are serialised.
    ///
    /// `activeFlowID` tracks "which open SAS flow does the SDK's next delegate
    /// callback apply to?" — the SDK has a single `SessionVerificationController`
    /// for the session and only one flow can be in-progress on it at a time, so
    /// the lifecycle delegate callbacks (`didStartSasVerification`,
    /// `didReceiveVerificationData`, `didFinish`, `didCancel`, `didFail`)
    /// don't carry a flow ID. `acceptIncoming` / `startSAS` set this pointer
    /// when they enter the flow; the delegate looks it up to find the right
    /// continuation to yield against.
    ///
    /// `roles[requestID]` records whether THIS side originated the SAS as a
    /// responder (we accepted an incoming request) or a requester (we sent
    /// the request). Wave 7: only the responder calls `startSasVerification`
    /// from `didAcceptVerificationRequest`. The SDK's state machine is
    /// asymmetric on which side issues `m.key.verification.start`, and
    /// double-issuing trips the MAC verification on both sides.
    private actor FlowStore {
        var controllers: [String: SessionVerificationControlling] = [:]
        var continuations: [String: AsyncStream<SasFlowState>.Continuation] = [:]
        var activeFlowID: String?
        var roles: [String: FlowRole] = [:]
        /// Sender's user ID per inbound flow ID. Captured in
        /// `routeIncomingRequest` from the SDK delegate's
        /// `didReceiveVerificationRequest` callback; consumed by
        /// `acceptIncoming` to call
        /// `controller.acknowledgeVerificationRequest(senderId:flowId:)`
        /// before `acceptVerificationRequest()`. The SDK requires this
        /// ack call to register which inbound request the next
        /// `accept` applies to — without it the accept silently no-ops.
        var senderIDs: [String: String] = [:]
        /// Continuation for the long-lived `incomingRequests()` stream. One per
        /// service instance — the SDK's delegate fires
        /// `didReceiveVerificationRequest` for every incoming request the
        /// session sees, and the `VerificationCenter` orchestrator drains
        /// them into its `pending` array.
        var incomingContinuation: AsyncStream<VerificationRequestSummary>.Continuation?
        /// Continuation for the long-lived `cancelledRequests()` stream.
        /// One per service instance. `routeSasCancelled` emits to it when
        /// the SDK fires `didCancel` for a flow that has no local SAS
        /// continuation observing it (e.g. partner cancelled before our
        /// user clicked the banner). `VerificationCenter` drains its
        /// pending list on each emission so stale banners disappear.
        var cancelledContinuation: AsyncStream<String>.Continuation?
        /// The SDK's shared `SessionVerificationController`. Retained here so
        /// the registered delegate (which the SDK only weakly tracks via the
        /// callback table) outlives the construction site. Cached so we never
        /// fetch a second controller for the same session.
        var sdkController: MatrixRustSDK.SessionVerificationController?

        /// Returns the previous controller (if any) so the caller can
        /// best-effort cancel it before it falls out of the dict.
        func register(controller: SessionVerificationControlling, for requestID: String) -> SessionVerificationControlling? {
            let previous = controllers[requestID]
            controllers[requestID] = controller
            return previous
        }

        func controller(for requestID: String) -> SessionVerificationControlling? {
            controllers[requestID]
        }

        /// Replacing a continuation must finish the prior one with a
        /// `.cancelled(reason: "Replaced by new flow")` so the upstream
        /// `for await` loop terminates instead of silently leaking. M3
        /// expert-QA fix: when the user taps "Verify with another device",
        /// cancels the sheet, then taps it again, the second `startSAS`
        /// re-enters here for the same `requestID`.
        func setContinuation(_ continuation: AsyncStream<SasFlowState>.Continuation, for requestID: String) {
            if let previous = continuations[requestID] {
                previous.yield(.cancelled(reason: "Replaced by new flow"))
                previous.finish()
            }
            continuations[requestID] = continuation
        }

        func continuation(for requestID: String) -> AsyncStream<SasFlowState>.Continuation? {
            continuations[requestID]
        }

        func clearContinuation(for requestID: String) {
            continuations.removeValue(forKey: requestID)
        }

        func clear(requestID: String) {
            controllers.removeValue(forKey: requestID)
            continuations.removeValue(forKey: requestID)
            roles.removeValue(forKey: requestID)
            senderIDs.removeValue(forKey: requestID)
            if activeFlowID == requestID {
                activeFlowID = nil
            }
        }

        func snapshot() -> [String: SessionVerificationControlling] {
            controllers
        }

        func setActiveFlowID(_ id: String?) {
            activeFlowID = id
        }

        func activeContinuation() -> (id: String, continuation: AsyncStream<SasFlowState>.Continuation)? {
            guard let id = activeFlowID, let cont = continuations[id] else { return nil }
            return (id, cont)
        }

        func activeRole() -> FlowRole? {
            guard let id = activeFlowID else { return nil }
            return roles[id]
        }

        func activeFlowIDValue() -> String? { activeFlowID }

        func setRole(_ role: FlowRole, for requestID: String) {
            roles[requestID] = role
        }

        func setSenderID(_ senderID: String, for requestID: String) {
            senderIDs[requestID] = senderID
        }

        func senderID(for requestID: String) -> String? {
            senderIDs[requestID]
        }

        func setIncomingContinuation(_ continuation: AsyncStream<VerificationRequestSummary>.Continuation?) {
            incomingContinuation?.finish()
            incomingContinuation = continuation
        }

        func setCancelledContinuation(_ continuation: AsyncStream<String>.Continuation?) {
            cancelledContinuation?.finish()
            cancelledContinuation = continuation
        }

        func setSDKController(_ controller: MatrixRustSDK.SessionVerificationController?) {
            sdkController = controller
        }

        func getSDKController() -> MatrixRustSDK.SessionVerificationController? {
            sdkController
        }

        func hasSDKController() -> Bool {
            sdkController != nil
        }
    }

    private let store = FlowStore()

    /// Strong reference to the registered SDK delegate. The SDK retains the
    /// delegate via its callback handle map; we hold it here too so deinit
    /// can call `setDelegate(nil)` cleanly. Element X's
    /// `WeakSessionVerificationControllerProxy` already breaks the back-edge
    /// (the wrapper holds `weak proxy`), so this strong reference does not
    /// create a cycle.
    private var registeredDelegate: WeakSessionVerificationControllerProxy?

    /// Retains the verification-state listener handle. Released on deinit.
    /// `periphery:ignore` style — only kept for retention.
    private var verificationStateListenerHandle: TaskHandle?

    /// Dedupe handle for the controller-build path. Wave 7 bug #2 fix:
    /// concurrent `awaitController()` callers all await the same Task<>,
    /// so we only ever fetch + register the SDK controller once.
    private var buildTask: Task<Void, Error>?

    /// Production init. Subscribes to the SDK's verification-state listener;
    /// the controller is built lazily the first time the listener fires
    /// `!= .unknown` (i.e. when the user identity is in the local crypto
    /// store and `getSessionVerificationController()` will not hang).
    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
        Task { [weak self] in
            await self?.installVerificationStateListener()
        }
    }

    /// Test-only init: no SDK client. Use this when exercising the
    /// controller-cache flow against `FakeSessionVerificationController`.
    /// SDK-bound surfaces will throw / produce empty streams.
    init() {
        self.provider = nil
        self.session = nil
    }

    deinit {
        // Tear down the listener so the SDK doesn't keep firing into a
        // deallocated service. The weak-wrapper delegate (held by the
        // SDK's callback handle map) already tolerates the service
        // disappearing — its `weak router` nils out and every callback
        // becomes a clean no-op. We can't `setDelegate(nil)` from here
        // because the SDK controller lives on the FlowStore actor and
        // deinit isn't `async`; the cached controller drops with the
        // actor when the service is released, which detaches the
        // delegate as a side-effect of the SDK's own retain-graph
        // teardown.
        verificationStateListenerHandle?.cancel()
    }

    // MARK: - Test surface

    /// Test seam: register a controller for a given request ID. Production code
    /// populates this from the SDK delegate's `didReceiveVerificationRequest`,
    /// which also captures the sender's user ID; tests can pass `senderID:` to
    /// override the default placeholder. The default keeps existing tests
    /// (that only care about controller routing) compiling, while
    /// `acceptIncoming`'s production-required `acknowledgeVerificationRequest`
    /// call still has a non-nil senderID to use.
    @discardableResult
    func register(
        controller: SessionVerificationControlling,
        for requestID: String,
        senderID: String = "@test-sender:test"
    ) async -> SessionVerificationControlling? {
        await store.setSenderID(senderID, for: requestID)
        return await store.register(controller: controller, for: requestID)
    }

    /// Test seam: explicitly set the senderID for an in-progress flow.
    /// Useful when a test needs to verify the senderID is forwarded to
    /// `acknowledgeVerificationRequest`.
    func setSenderID(_ senderID: String, for requestID: String) async {
        await store.setSenderID(senderID, for: requestID)
    }

    /// Test seam: snapshot the activeFlows cache so tests can assert removal.
    func activeFlowsSnapshot() async -> [String: SessionVerificationControlling] {
        await store.snapshot()
    }

    /// Test seam: returns true once the `cancelledRequests()` stream's
    /// continuation has been installed in the FlowStore actor. The
    /// AsyncStream initializer schedules a fire-and-forget Task to do
    /// the actor-hop registration; on a slow scheduler (CI) a test that
    /// triggers `routeSasCancelled` immediately after subscribing can
    /// race that Task and miss the broadcast. Tests poll this until
    /// true before exercising the cancel path.
    func cancelledContinuationIsRegistered() async -> Bool {
        await store.cancelledContinuation != nil
    }

    /// Test seam: set the in-progress flow ID so subsequent `routeSas…`
    /// callbacks find the right continuation.
    func setActiveFlowID(_ id: String?) async {
        await store.setActiveFlowID(id)
    }

    /// Test seam: set a flow role so `routeAcceptedVerificationRequest`
    /// can branch responder/requester deterministically in unit tests.
    func setFlowRole(_ role: FlowRole, for requestID: String) async {
        await store.setRole(role, for: requestID)
    }

    // MARK: - Lifecycle

    /// Backward-compat helper retained for the `MatronApp` host's
    /// `.task { try? await dependencies.verificationService(for: session).start() }`
    /// blocks. Wave 7 made this a thin wait-for-controller wrapper —
    /// the actual subscription is installed in `init` and the controller
    /// builds reactively when the SDK's verification-state listener fires
    /// `!= .unknown`. Calling this is no longer required for correctness;
    /// the hosts now drop the `.task` calls (Wave 7 bug #7 fix).
    ///
    /// Kept for the test surface and any future caller that explicitly
    /// wants to block until the controller is wired.
    public func start() async throws {
        Self.logger.notice("start: enter (Wave 7 — wait-for-controller helper)")
        guard provider != nil, session != nil else {
            Self.logger.error("start: notConfigured (provider/session nil)")
            throw VerificationError.notConfigured
        }
        try await awaitController()
        Self.logger.notice("start: controller ready — exit")
    }

    static let logger = os.Logger(subsystem: "chat.matron", category: "verification-live")

    // MARK: - VerificationService

    public func isThisDeviceVerified() async throws -> Bool {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        return client.encryption().verificationState() == .verified
    }

    public func hasOtherVerifiedDevices() async throws -> Bool {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        return try await client.encryption().hasDevicesToVerifyAgainst()
    }

    public func isUserVerified(matrixID: String) async throws -> UserVerificationResult {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        guard let identity = try await client.encryption().userIdentity(
            userId: matrixID,
            fallbackToServer: false
        ) else {
            return .unknown
        }
        return identity.isVerified() ? .verified : .unverified
    }

    public func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { continuation in
            let store = self.store
            Task {
                await store.setIncomingContinuation(continuation)
            }
            continuation.onTermination = { _ in
                Task { await store.setIncomingContinuation(nil) }
            }
        }
    }

    public func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { continuation in
            let store = self.store
            Task {
                await store.setCancelledContinuation(continuation)
            }
            continuation.onTermination = { _ in
                Task { await store.setCancelledContinuation(nil) }
            }
        }
    }

    public func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        Self.logger.notice("startSAS: enter userID=\(userID, privacy: .public) deviceID=\(deviceID ?? "nil", privacy: .public)")
        return AsyncStream { continuation in
            guard provider != nil, session != nil else {
                Self.logger.error("startSAS: notConfigured")
                continuation.yield(.cancelled(reason: "VerificationServiceLive not configured with a Client"))
                continuation.finish()
                return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    // Wait for the SDK controller to be wired (Wave 7
                    // bug #1 + #2 fix: lazy + deduped). The
                    // verification-state listener installed in init
                    // builds the controller the first time the listener
                    // fires `!= .unknown`; if the listener hasn't
                    // landed yet, this awaits it.
                    try await self.awaitController()
                    guard let controller = await self.store.getSDKController() else {
                        throw VerificationError.notConfigured
                    }
                    Self.logger.notice("startSAS: using cached SDK controller (handle: \(ObjectIdentifier(controller).hashValue, privacy: .public))")
                    let wrapped = LiveSessionVerificationController(controller)
                    let priorController = await self.store.register(controller: wrapped, for: userID)
                    if let priorController {
                        try? await priorController.cancelVerification()
                    }
                    await self.store.setContinuation(continuation, for: userID)
                    // Wave 7 bug #6: the requester side must NEVER call
                    // `startSasVerification()`. Mark this flow as a
                    // requester so the delegate's
                    // `didAcceptVerificationRequest` handler skips the
                    // SAS-start call for this flow.
                    await self.store.setRole(.requester, for: userID)
                    await self.store.setActiveFlowID(userID)
                    // Prime the local identity cache via /keys/query
                    // before sending the verification request. Without
                    // this, a brand-new sign-in (or a session whose
                    // local crypto store hasn't yet seen the partner's
                    // current device_id) sends `.request` against a
                    // stale device list — the partner's `.ready`
                    // response then arrives from a `from_device` the
                    // local rust olm verification machine doesn't
                    // recognise and gets silently dropped, leaving
                    // the requester stuck at "Starting verification…"
                    // forever. `userIdentity(fallbackToServer: true)`
                    // mirrors Element X's `ClientProxy.swift:1231` shape
                    // and forces the SDK to issue a `/keys/query` for
                    // the user before we proceed.
                    if let provider = self.provider, let session = self.session {
                        let client = try? await provider.client(for: session)
                        _ = try? await client?.encryption().userIdentity(
                            userId: userID,
                            fallbackToServer: true
                        )
                    }
                    // Dispatch: user-verification vs self-device verification.
                    //
                    // PR #3 review #16 — the per-bot verify path
                    // (`VerifyBotSheet` / `MacVerifyBotSheet`) calls
                    // `startSAS(withUser: botMatrixID, deviceID: nil)` for a
                    // foreign user. Under the previous shape (`deviceID
                    // != nil` → user-verify, `deviceID == nil` →
                    // device-verify) this incorrectly routed bot
                    // verification to the self-device path. The bot's
                    // identity was never trusted, so the unverified-bot
                    // banner re-appeared immediately post-flow.
                    //
                    // The correct branch is user vs self, not deviceID
                    // presence: if the requested userID is someone else
                    // we always want user-verification; if it is our own
                    // user we want self-device verification (SAS against
                    // another of OUR devices). `deviceID` is currently
                    // unused on either SDK call (the SDK chooses targets
                    // internally) — kept on the protocol for future use
                    // once we expose per-device targeting in the UI.
                    let selfUserID = self.session?.userID
                    if let selfUserID, userID == selfUserID {
                        Self.logger.notice("startSAS: self-user — calling requestDeviceVerificationIfPossible()")
                        try await wrapped.requestDeviceVerificationIfPossible()
                    } else {
                        Self.logger.notice("startSAS: foreign user — calling requestUserVerificationIfPossible(\(userID, privacy: .public))")
                        try await wrapped.requestUserVerificationIfPossible(userID: userID)
                    }
                    Self.logger.notice("startSAS: SDK request returned — yielding .requested")
                    continuation.yield(.requested)
                    // Further state transitions (`.readyForEmoji`, `.verified`,
                    // `.cancelled`) arrive via the SDK delegate registered
                    // by `installVerificationStateListener`'s build path
                    // and routed through `routeSas…`.
                } catch {
                    await self.store.clear(requestID: userID)
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        Self.logger.notice("acceptIncoming: enter requestID=\(requestID, privacy: .public)")
        return AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                await self.store.setContinuation(continuation, for: requestID)
                guard let controller = await self.store.controller(for: requestID) else {
                    Self.logger.error("acceptIncoming: NO CONTROLLER for requestID=\(requestID, privacy: .public)")
                    continuation.yield(.cancelled(reason: "Unknown request: \(requestID)"))
                    continuation.finish()
                    await self.store.clearContinuation(for: requestID)
                    return
                }
                await self.store.setRole(.responder, for: requestID)
                await self.store.setActiveFlowID(requestID)
                do {
                    // Element X parity: register the inbound flow with the
                    // SDK BEFORE accepting. Without this call, the SDK's
                    // session-verification controller has no current
                    // active inbound request, and `acceptVerificationRequest`
                    // silently no-ops (returns OK without queuing the
                    // outgoing `m.key.verification.ready` to-device event).
                    // The senderID was captured in `routeIncomingRequest`
                    // from `didReceiveVerificationRequest`; if it's
                    // missing here something has gone wrong with the
                    // route bookkeeping — log + bail rather than send a
                    // garbage placeholder.
                    guard let senderID = await self.store.senderID(for: requestID) else {
                        Self.logger.error("acceptIncoming: NO SENDER_ID stored for requestID — cannot acknowledge")
                        continuation.yield(.cancelled(reason: "Missing senderID for request \(requestID)"))
                        continuation.finish()
                        await self.store.clearContinuation(for: requestID)
                        return
                    }
                    Self.logger.notice("acceptIncoming: calling acknowledgeVerificationRequest(senderId=\(senderID, privacy: .public), flowId=\(requestID, privacy: .public))")
                    try await controller.acknowledgeVerificationRequest(senderId: senderID, flowId: requestID)
                    Self.logger.notice("acceptIncoming: acknowledgeVerificationRequest returned OK")
                    Self.logger.notice("acceptIncoming: calling acceptVerificationRequest")
                    try await controller.acceptVerificationRequest()
                    Self.logger.notice("acceptIncoming: acceptVerificationRequest returned OK — yielding .requested")
                    continuation.yield(.requested)
                    // No `startSasVerification()` call here — the
                    // Matrix spec puts `m.key.verification.start` on
                    // the *initiator*. The responder only sends
                    // `.ready` (via acceptVerificationRequest) and
                    // then waits for the initiator to send `.start`,
                    // which matrix-rust-sdk receives + processes
                    // automatically: `didStartSasVerification` fires,
                    // then `didReceiveVerificationData` fires with the
                    // emoji set, which `routeSasData` turns into
                    // `.readyForEmoji`. No responder-side
                    // `startSasVerification` is needed (or, indeed,
                    // possible — calling it before the initiator
                    // sends `.start` throws "Verification request
                    // missing").
                } catch {
                    Self.logger.error("acceptIncoming: acceptVerificationRequest threw: \(error.localizedDescription, privacy: .public)")
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                    await self.store.clearContinuation(for: requestID)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func confirmEmojiMatch(requestID: String) async throws {
        Self.logger.notice("confirmEmojiMatch: enter requestID=\(requestID, privacy: .public)")
        guard let controller = await store.controller(for: requestID) else {
            Self.logger.error("confirmEmojiMatch: NO CONTROLLER for requestID")
            throw VerificationError.unknownRequest(requestID)
        }
        Self.logger.notice("confirmEmojiMatch: calling approveVerification()")
        try await controller.approveVerification()
        Self.logger.notice("confirmEmojiMatch: approveVerification() returned OK")
        // Yield `.awaitingConfirmation` so the SAS view can swap from the
        // "They match / They don't match" buttons to a "Waiting for the
        // other device…" ProgressView while we wait for the other peer
        // to also approve. Without this yield the view stays at
        // `.readyForEmoji` until the SDK fires `didFinish` (which only
        // happens after the OTHER peer also approves), making local
        // confirmation feel unresponsive — the user clicks "They match"
        // and the UI doesn't acknowledge the click. The `.verified` /
        // `.cancelled` transition still arrives via the SDK delegate
        // through `routeSasFinished` / `routeSasCancelled`.
        if let continuation = await store.continuation(for: requestID) {
            continuation.yield(.awaitingConfirmation)
        }
    }

    public func cancel(requestID: String, reason: String) async throws {
        Self.logger.notice("cancel: enter requestID=\(requestID, privacy: .public) reason=\(reason, privacy: .public)")
        guard let controller = await store.controller(for: requestID) else {
            if let continuation = await store.continuation(for: requestID) {
                continuation.yield(.cancelled(reason: reason))
                continuation.finish()
            }
            await store.clearContinuation(for: requestID)
            return
        }
        if let continuation = await store.continuation(for: requestID) {
            continuation.yield(.cancelled(reason: reason))
            continuation.finish()
        }
        await store.clear(requestID: requestID)
        try await controller.cancelVerification()
    }

    // MARK: - Delegate routing

    /// Routes the SDK delegate's `didReceiveVerificationRequest` callback
    /// into the FlowStore: registers the (single, shared) SDK controller
    /// under the new flow ID, marks it active, marks the role as responder
    /// (we are receiving someone else's request), and yields a summary on
    /// the long-lived `incomingRequests()` stream so the
    /// `VerificationCenter` banner picks it up.
    func routeIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) async {
        Self.logger.notice("routeIncomingRequest: requestID=\(requestID, privacy: .public) from=\(otherUserID, privacy: .public)")
        let summary = VerificationRequestSummary(
            id: requestID,
            otherUserID: otherUserID,
            otherDeviceID: otherDeviceID,
            createdAt: Date()
        )
        _ = await store.register(controller: controller, for: requestID)
        await store.setRole(.responder, for: requestID)
        await store.setSenderID(otherUserID, for: requestID)
        await store.setActiveFlowID(requestID)
        if let cont = await store.incomingContinuation {
            cont.yield(summary)
        }
    }

    /// Routes the SDK delegate's `didAcceptVerificationRequest` callback.
    ///
    /// Per the Matrix spec, ONLY the requester (initiator) sends
    /// `m.key.verification.start`. The responder issues `.ready` via
    /// `acceptVerificationRequest()` and then waits for the
    /// requester's `.start` to arrive over to-device — matrix-rust-sdk
    /// auto-progresses the responder's state machine on receipt
    /// (`didStartSasVerification` then `didReceiveVerificationData`
    /// fire from inside the sync delivery path). Calling
    /// `startSasVerification()` on the responder side issues a SECOND
    /// `.start` event; the requester's SDK sees two and cancels with
    /// "duplicate start".
    ///
    /// Wave 7 bug #6 originally landed exactly this guard. A
    /// post-Wave-7 commit reverted it because verify-sdk-against-partner
    /// (matron-as-requester vs matrix-js-sdk) appeared to deadlock at
    /// `phase=Ready` without it. Live evidence in run
    /// `tests/integration/artifacts/20260504-224505/matron-mac-show.log`
    /// shows the unguarded shape causes `didCancel` against a
    /// matrix-rust-sdk responder (matron-vs-matron-ui). Re-adding the
    /// guard. If verify-sdk regresses afterward, the matrix-js-sdk
    /// peer has a different code path that needs targeted handling
    /// (peer-SDK detection or a manual `.start` resend), not blanket
    /// double-start.
    func routeAcceptedVerificationRequest() async {
        Self.logger.notice("routeAcceptedVerificationRequest: enter")
        let role = await store.activeRole()
        let activeID = await store.activeFlowIDValue()
        Self.logger.notice("routeAcceptedVerificationRequest: role=\(String(describing: role), privacy: .public) activeFlowID=\(activeID ?? "nil", privacy: .public)")
        guard let activeID, let controller = await store.controller(for: activeID) else {
            Self.logger.error("routeAcceptedVerificationRequest: NO CONTROLLER for active flow")
            return
        }
        if role == .responder {
            Self.logger.notice("routeAcceptedVerificationRequest: role=responder — skipping startSasVerification (requester-only per Matrix spec)")
            return
        }
        do {
            Self.logger.notice("routeAcceptedVerificationRequest: calling startSasVerification() (role=\(String(describing: role), privacy: .public))")
            try await controller.startSasVerification()
            Self.logger.notice("routeAcceptedVerificationRequest: startSasVerification() returned OK")
        } catch {
            Self.logger.error("routeAcceptedVerificationRequest: startSasVerification() threw: \(error.localizedDescription, privacy: .public)")
            if let cont = await store.continuation(for: activeID) {
                cont.yield(.cancelled(reason: error.localizedDescription))
                cont.finish()
            }
            await store.clear(requestID: activeID)
        }
    }

    /// Routes the SDK delegate's `didStartSasVerification` callback.
    func routeSasStarted() async {
        let active = await store.activeContinuation()
        Self.logger.notice("routeSasStarted: activeFlowID=\(active?.id ?? "nil", privacy: .public)")
    }

    /// Routes the SDK delegate's `didReceiveVerificationData(SessionVerificationData)`.
    func routeSasData(_ data: SessionVerificationData) async {
        Self.logger.notice("routeSasData: enter")
        guard let active = await store.activeContinuation() else {
            Self.logger.error("routeSasData: NO ACTIVE CONTINUATION — drop on floor")
            return
        }
        Self.logger.notice("routeSasData: activeFlowID=\(active.id, privacy: .public)")
        switch data {
        case .emojis(let emojis, _):
            let mapped = emojis.map { SasEmoji(symbol: $0.symbol(), description: $0.description()) }
            Self.logger.notice("routeSasData: yielding .readyForEmoji(count: \(mapped.count, privacy: .public))")
            active.continuation.yield(.readyForEmoji(mapped))
        case .decimals:
            active.continuation.yield(.cancelled(reason: "Decimal SAS is not supported; use a peer that speaks emoji SAS."))
            active.continuation.finish()
            await store.clear(requestID: active.id)
        }
    }

    /// Routes the SDK delegate's `didFinish` callback.
    func routeSasFinished() async {
        Self.logger.notice("routeSasFinished: enter")
        guard let active = await store.activeContinuation() else {
            Self.logger.error("routeSasFinished: NO ACTIVE CONTINUATION")
            return
        }
        Self.logger.notice("routeSasFinished: yielding .verified for \(active.id, privacy: .public)")
        active.continuation.yield(.verified)
        active.continuation.finish()
        await store.clear(requestID: active.id)
    }

    /// Routes the SDK delegate's `didCancel` callback.
    ///
    /// Two paths: when there's an active continuation (a SAS sheet is
    /// currently observing the flow), yield `.cancelled` so the UI
    /// renders the red shield + Close button. When there's no active
    /// continuation (the partner cancelled before our user opened the
    /// banner, or the SDK's inactivity timeout fired), broadcast the
    /// flow ID on the `cancelledRequests()` stream so
    /// `VerificationCenter` drains its pending list and the chat-list
    /// banner disappears. Either way, clear the FlowStore entry so a
    /// subsequent `acceptIncoming` for the same ID can't accidentally
    /// reuse stale state.
    func routeSasCancelled() async {
        Self.logger.notice("routeSasCancelled: enter")
        if let active = await store.activeContinuation() {
            Self.logger.notice("routeSasCancelled: yielding for \(active.id, privacy: .public)")
            active.continuation.yield(.cancelled(reason: "Verification cancelled"))
            active.continuation.finish()
            await store.clear(requestID: active.id)
            return
        }
        if let activeID = await store.activeFlowIDValue() {
            Self.logger.notice("routeSasCancelled: no active continuation; broadcasting cancel for \(activeID, privacy: .public) so banner can drain")
            if let cont = await store.cancelledContinuation {
                cont.yield(activeID)
            }
            await store.clear(requestID: activeID)
            return
        }
        Self.logger.error("routeSasCancelled: NO ACTIVE CONTINUATION and no activeFlowID — cancel arrived for an unknown flow")
    }

    /// Routes the SDK delegate's `didFail` callback.
    func routeSasFailed() async {
        Self.logger.notice("routeSasFailed: enter")
        guard let active = await store.activeContinuation() else {
            Self.logger.error("routeSasFailed: NO ACTIVE CONTINUATION")
            return
        }
        Self.logger.notice("routeSasFailed: yielding for \(active.id, privacy: .public)")
        active.continuation.yield(.cancelled(reason: "Verification failed"))
        active.continuation.finish()
        await store.clear(requestID: active.id)
    }

    // MARK: - Private — Wave 7 verification-state listener + lazy controller build

    /// Subscribes to `client.encryption().verificationStateListener(...)`
    /// and keeps the `TaskHandle` alive for the lifetime of the service.
    /// On every non-`.unknown` state change, attempts to build the
    /// SessionVerificationController (idempotent — only the first call
    /// actually fetches; subsequent calls no-op via the dedupe Task<>).
    ///
    /// `.unknown` is the SDK's way of saying "the user identity isn't yet
    /// in the local crypto store — `getSessionVerificationController()`
    /// would hang waiting for `/keys/query`." Element X uses this exact
    /// signal as the "safe to fetch" gate
    /// (see `ClientProxy.updateVerificationState`).
    private func installVerificationStateListener() async {
        guard let provider, let session else { return }
        do {
            let client = try await provider.client(for: session)
            // Snapshot the current state in case the listener is slow to
            // fire its initial value — Element X's
            // `await updateVerificationState(client.encryption().verificationState())`
            // does the same one-shot poll alongside the listener install.
            let initial = client.encryption().verificationState()
            Self.logger.notice("installVerificationStateListener: initial state=\(String(describing: initial), privacy: .public)")
            if initial != .unknown {
                Task { [weak self] in
                    try? await self?.awaitController()
                }
            }
            verificationStateListenerHandle = client.encryption().verificationStateListener(
                listener: VerificationStateSDKListener { [weak self] state in
                    Self.logger.notice("verificationStateListener: fired with \(String(describing: state), privacy: .public)")
                    guard state != .unknown else { return }
                    Task { [weak self] in
                        try? await self?.awaitController()
                    }
                }
            )
        } catch {
            Self.logger.error("installVerificationStateListener: failed to fetch client: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Idempotent + concurrent-safe controller-build path. Every caller
    /// awaits the same in-flight `Task<Void, Error>?` so the SDK is never
    /// asked for a second `getSessionVerificationController()` (Wave 7
    /// bug #2 fix). MainActor-isolated so the `buildTask` mutation is
    /// safe without an extra lock.
    @MainActor
    private func awaitController() async throws {
        if await store.hasSDKController() {
            return
        }
        if let buildTask {
            try await buildTask.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.buildController()
        }
        buildTask = task
        do {
            try await task.value
            buildTask = nil
        } catch {
            buildTask = nil
            throw error
        }
    }

    /// Single-shot SDK-controller fetch + delegate registration. Called
    /// only from `awaitController` (which dedupes concurrent callers via
    /// `buildTask`). Mirrors Element X's
    /// `buildSessionVerificationControllerProxyIfPossible`.
    private func buildController() async throws {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        if await store.hasSDKController() {
            Self.logger.notice("buildController: idempotent — controller already cached")
            return
        }
        let client = try await provider.client(for: session)
        Self.logger.notice("buildController: fetching SessionVerificationController")
        // `getSessionVerificationController()` can throw
        // `ClientError.Generic("Failed retrieving user identity")` when
        // `verificationStateListener` has fired `!= .unknown` but
        // `/keys/query` hasn't yet returned the cross-signing identity
        // for this user. Retry on transient errors —
        // `MatronIntegrationTests/VerificationFlowIntegrationTests.testVerifyWithOtherDeviceAgainstPartner`
        // documents the same behaviour at the test level (60 × 500ms);
        // production code needs the same backoff so a fresh second-device
        // sign-in doesn't strand the verify-gate's `startSAS` task on a
        // silently-swallowed error. Log every attempt so next-time
        // diagnosis isn't another archaeology trip through `try?`.
        let controller: MatrixRustSDK.SessionVerificationController = try await {
            let maxAttempts = 60
            var attempt = 0
            while true {
                attempt += 1
                do {
                    return try await client.getSessionVerificationController()
                } catch {
                    if attempt >= maxAttempts {
                        Self.logger.error("buildController: getSessionVerificationController() failed after \(attempt, privacy: .public) attempts: \(error.localizedDescription, privacy: .public)")
                        throw error
                    }
                    Self.logger.notice("buildController: getSessionVerificationController() threw on attempt \(attempt, privacy: .public)/\(maxAttempts, privacy: .public): \(error.localizedDescription, privacy: .public) — retrying in 500ms")
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }()
        Self.logger.notice("buildController: fetched (handle: \(ObjectIdentifier(controller).hashValue, privacy: .public)) on attempt path")
        await store.setSDKController(controller)
        let weakDelegate = WeakSessionVerificationControllerProxy(
            router: self,
            sharedController: controller
        )
        self.registeredDelegate = weakDelegate
        controller.setDelegate(delegate: weakDelegate)
        Self.logger.notice("buildController: setDelegate completed")
    }
}

/// Errors surfaced by `VerificationServiceLive`. Equatable so tests can assert
/// the exact case without string-matching.
public enum VerificationError: Error, Equatable {
    case unknownRequest(String)
    case notConfigured
}

/// Whether THIS side of an in-progress SAS originated as a responder (we
/// accepted an incoming request) or a requester (we sent the request).
/// Wave 7 bug #6: only the responder may call `startSasVerification()`
/// from the SDK's `didAcceptVerificationRequest` callback. Both sides
/// calling it sends two `m.key.verification.start` events and trips the
/// SAS MAC verification on both ends. File-scoped so the FlowStore actor
/// and the public test seam can share the same nominal type.
enum FlowRole {
    case responder
    case requester
}

/// Production adapter — bridges our protocol to the real SDK type. The SDK's
/// `SessionVerificationController` already exposes the five methods we need with
/// matching signatures (verified against matrix-rust-components-swift v26.04.01),
/// so this is a pure forwarding shim.
final class LiveSessionVerificationController: SessionVerificationControlling, @unchecked Sendable {
    let inner: MatrixRustSDK.SessionVerificationController
    init(_ inner: MatrixRustSDK.SessionVerificationController) { self.inner = inner }

    func acknowledgeVerificationRequest(senderId: String, flowId: String) async throws {
        try await inner.acknowledgeVerificationRequest(senderId: senderId, flowId: flowId)
    }
    func acceptVerificationRequest() async throws { try await inner.acceptVerificationRequest() }
    func startSasVerification()      async throws { try await inner.startSasVerification() }
    func approveVerification()       async throws { try await inner.approveVerification() }
    func declineVerification()       async throws { try await inner.declineVerification() }
    func cancelVerification()        async throws { try await inner.cancelVerification() }

    func requestDeviceVerificationIfPossible() async throws {
        try await inner.requestDeviceVerification()
    }

    func requestUserVerificationIfPossible(userID: String) async throws {
        try await inner.requestUserVerification(userId: userID)
    }
}

/// Single-purpose `VerificationStateListener` adapter. We don't import
/// Element X's generic `SDKListener<T>` (it's tied to the `MXLog` style +
/// the rest of their helper graph); a one-shot adapter is simpler and
/// mirrors the small surface we use.
final class VerificationStateSDKListener: VerificationStateListener, @unchecked Sendable {
    private let onUpdateClosure: (VerificationState) -> Void

    init(_ onUpdateClosure: @escaping (VerificationState) -> Void) {
        self.onUpdateClosure = onUpdateClosure
    }

    func onUpdate(status: VerificationState) {
        onUpdateClosure(status)
    }
}

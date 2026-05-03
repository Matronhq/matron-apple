import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

/// Production implementation of `VerificationService`. Wraps the SDK's session
/// verification surface (`MatrixRustSDK.SessionVerificationController`) behind a
/// per-request controller cache so the UI can drive accept / confirm / cancel
/// against an `AsyncStream<SasFlowState>` without holding raw SDK delegate objects.
///
/// Concurrency model: the per-request `controllers` (controllers) and
/// `continuations` (open SAS streams) are stored on a private `actor` so
/// reads + writes from accept / confirm / cancel are serialised. The class
/// itself is `@unchecked Sendable` because all mutation hops through the actor.
///
/// Delegate wiring: `start()` fetches `client.getSessionVerificationController()`,
/// retains it, constructs a `LiveSessionVerificationDelegate`, and registers it
/// against the SDK. Subsequent SDK callbacks
/// (`didReceiveVerificationRequest`, `didStartSasVerification`,
/// `didReceiveVerificationData`, `didFinish`, `didCancel`, `didFail`) route
/// through this service's `route…` entry points so the UI's open
/// `AsyncStream<SasFlowState>` continuations advance through the SAS flow.
/// Without `start()` the service still satisfies its protocol shape (test
/// surface) but `incomingRequests()` finishes empty and SAS flows hang at
/// `.requested` because no delegate ever fires `.readyForEmoji([…])`. The
/// production hosts (`MatronApp` / `MatronMacApp`) call `start()` from a
/// `.task` block alongside `syncService.start()`.
///
/// Test surface: callers can construct `VerificationServiceLive()` with no args
/// for unit tests that exercise the controller-cache flow against
/// `FakeSessionVerificationController`. The SDK-bound surfaces
/// (`isThisDeviceVerified`, `incomingRequests`, `startSAS`) require a live
/// `Client` and throw / return empty when the no-arg init was used; they are
/// integration-tested in Phase 7 against a real homeserver. Tests can also
/// drive the delegate-routed paths via `routeSasStarted()` / `routeSasData(_:)`
/// / `routeSasFinished()` / `routeSasCancelled()` directly.
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
    private actor FlowStore {
        var controllers: [String: SessionVerificationControlling] = [:]
        var continuations: [String: AsyncStream<SasFlowState>.Continuation] = [:]
        var activeFlowID: String?
        /// Continuation for the long-lived `incomingRequests()` stream. One per
        /// service instance — the SDK's delegate fires
        /// `didReceiveVerificationRequest` for every incoming request the
        /// session sees, and the `VerificationCenter` orchestrator drains
        /// them into its `pending` array. Set by `incomingRequests()`,
        /// cleared on `stop()`.
        var incomingContinuation: AsyncStream<VerificationRequestSummary>.Continuation?
        /// The SDK's shared `SessionVerificationController`. Retained here so
        /// the registered delegate (which the SDK only weakly tracks via the
        /// callback table) outlives the `start()` call site. Cached so
        /// `start()` is idempotent — second call no-ops if already set.
        var sdkController: MatrixRustSDK.SessionVerificationController?

        func register(controller: SessionVerificationControlling, for requestID: String) {
            controllers[requestID] = controller
        }

        func controller(for requestID: String) -> SessionVerificationControlling? {
            controllers[requestID]
        }

        func setContinuation(_ continuation: AsyncStream<SasFlowState>.Continuation, for requestID: String) {
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

        func setIncomingContinuation(_ continuation: AsyncStream<VerificationRequestSummary>.Continuation?) {
            // Finishing the previous continuation (if any) keeps a re-entered
            // `incomingRequests()` consumer from leaking the old stream. The
            // production VerificationCenter only calls this once per session,
            // but tests / preview re-mounts could drive a second call.
            incomingContinuation?.finish()
            incomingContinuation = continuation
        }

        func setSDKController(_ controller: MatrixRustSDK.SessionVerificationController?) {
            sdkController = controller
        }

        func hasSDKController() -> Bool {
            sdkController != nil
        }
    }

    private let store = FlowStore()

    /// Strong reference to the registered SDK delegate. The SDK retains the
    /// delegate via its callback handle map, but holding it here too keeps the
    /// reference graph explicit and lets `start()` no-op cleanly on a second
    /// call (we test for the SDK controller having been fetched, not for the
    /// delegate being non-nil — same idempotency check, but stored separately
    /// so the `weak` link from the delegate back to `self` doesn't risk
    /// premature deallocation if the SDK ever drops its callback handle).
    private var registeredDelegate: LiveSessionVerificationDelegate?

    /// Production init. Pass the shared `ClientProvider` + the active `UserSession`.
    public init(provider: ClientProvider, session: UserSession) {
        self.provider = provider
        self.session = session
    }

    /// Test-only init: no SDK client. Use this when exercising the controller-cache
    /// flow against `FakeSessionVerificationController`. SDK-bound surfaces will
    /// throw / produce empty streams.
    init() {
        self.provider = nil
        self.session = nil
    }

    // MARK: - Test surface

    /// Test seam: register a controller for a given request ID. Production code
    /// populates this from `IncomingVerificationListening.onUpdate`.
    func register(controller: SessionVerificationControlling, for requestID: String) async {
        await store.register(controller: controller, for: requestID)
    }

    /// Test seam: snapshot the activeFlows cache so tests can assert removal.
    func activeFlowsSnapshot() async -> [String: SessionVerificationControlling] {
        await store.snapshot()
    }

    /// Test seam: set the in-progress flow ID so subsequent `routeSas…`
    /// callbacks find the right continuation. Production code sets this
    /// inside `acceptIncoming` / `startSAS` once those flows have opened
    /// their continuation.
    func setActiveFlowID(_ id: String?) async {
        await store.setActiveFlowID(id)
    }

    // MARK: - Lifecycle

    /// Idempotent. Fetches the SDK's session-verification controller, retains
    /// it on the FlowStore, and registers `LiveSessionVerificationDelegate`
    /// so subsequent SDK callbacks
    /// (`didReceiveVerificationRequest` / `didStartSasVerification` /
    /// `didReceiveVerificationData` / `didFinish` / `didCancel` / `didFail`)
    /// route through this service. Without this call, `incomingRequests()`
    /// finishes empty and SAS flows hang at `.requested` (the delegate is
    /// the only producer of `.readyForEmoji([…])` / `.verified` / `.cancelled`).
    ///
    /// Production hosts (`MatronApp` / `MatronMacApp`) call this from a
    /// `.task` alongside `syncService.start()`. Safe to call from any actor —
    /// hops to the FlowStore for the idempotency check.
    public func start() async throws {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        // Idempotency: if the SDK controller is already cached, the delegate is
        // already wired. Re-firing on a SwiftUI view remount or a `.task`
        // re-trigger must not double-register, which would cause two delegate
        // notifications per SDK event.
        if await store.hasSDKController() { return }
        let client = try await provider.client(for: session)
        let controller = try await client.getSessionVerificationController()
        await store.setSDKController(controller)
        let delegate = LiveSessionVerificationDelegate(router: self, sharedController: controller)
        self.registeredDelegate = delegate
        controller.setDelegate(delegate: delegate)
    }

    // MARK: - VerificationService

    public func isThisDeviceVerified() async throws -> Bool {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        return client.encryption().verificationState() == .verified
    }

    /// Per-user verification check for the chat-view banner (spec §7.3, §7.5).
    /// Looks up the SDK's `UserIdentity` for `matrixID` and reads its
    /// `isVerified()` flag — that's already account-scoped (the SDK requires
    /// our own identity to be verified for another user's identity to count
    /// as verified, so the banner correctly hides only when both sides are
    /// trusted). `fallbackToServer: false` avoids blocking the banner on a
    /// network round-trip; the local crypto store already has the identity
    /// the SDK needs to make this decision once any prior to-device or
    /// /keys/query has landed (which the sliding-sync warmup already drives).
    public func isUserVerified(matrixID: String) async throws -> Bool {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        guard let identity = try await client.encryption().userIdentity(
            userId: matrixID,
            fallbackToServer: false
        ) else {
            // Unknown identity → not verified. Caller's banner will prompt
            // the user to verify, matching §7.5's "nothing auto-trusted".
            return false
        }
        return identity.isVerified()
    }

    public func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        // Stash a continuation on the FlowStore so the SDK delegate's
        // `didReceiveVerificationRequest` can yield into it. Without `start()`
        // having been called, no delegate exists and the stream never produces
        // — that's the test-no-arg-init / not-configured branch the protocol
        // contract already documents. `onTermination` clears the FlowStore
        // pointer so a cancelled stream doesn't hold the continuation alive.
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

    public func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        AsyncStream { continuation in
            guard let provider, let session else {
                continuation.yield(.cancelled(reason: "VerificationServiceLive not configured with a Client"))
                continuation.finish()
                return
            }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let client = try await provider.client(for: session)
                    let controller = try await client.getSessionVerificationController()
                    let wrapped = LiveSessionVerificationController(controller)
                    // Use the user ID as the cache key for self-verification flows.
                    // Per-flow controllers replace this entry when a delegate fires.
                    await self.store.register(controller: wrapped, for: userID)
                    await self.store.setContinuation(continuation, for: userID)
                    // Mark this as the in-progress flow so the delegate's
                    // lifecycle callbacks know which continuation to drive.
                    // The SDK's session-verification controller is a singleton
                    // per session, so only one flow can be active at a time —
                    // the same activeFlowID slot is reused across flows.
                    await self.store.setActiveFlowID(userID)
                    if let deviceID, !deviceID.isEmpty {
                        // Targeting a specific user/device pair: request user verification
                        // (the SDK's per-device targeting happens through the verification
                        // request payload, not this method's signature in v26).
                        try await wrapped.requestUserVerificationIfPossible(userID: userID)
                    } else {
                        try await wrapped.requestDeviceVerificationIfPossible()
                    }
                    continuation.yield(.requested)
                    // Further state transitions (`.readyForEmoji`, `.verified`,
                    // `.cancelled`) arrive via the `SessionVerificationControllerDelegate`
                    // wired by `start()` and routed through `routeSas…`.
                } catch {
                    // Bugbot caught: register/setContinuation happen *before*
                    // the throwing SDK call. Without `clear()` here, the
                    // FlowStore retains stale controller + finished-continuation
                    // entries keyed by userID. Mirrors the cleanup that
                    // acceptIncoming / confirmEmojiMatch / cancel already do.
                    await self.store.clear(requestID: userID)
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return }
                await self.store.setContinuation(continuation, for: requestID)
                guard let controller = await self.store.controller(for: requestID) else {
                    continuation.yield(.cancelled(reason: "Unknown request: \(requestID)"))
                    continuation.finish()
                    await self.store.clearContinuation(for: requestID)
                    return
                }
                // Mark this as the in-progress flow so the delegate's
                // lifecycle callbacks know which continuation to drive.
                await self.store.setActiveFlowID(requestID)
                do {
                    try await controller.acceptVerificationRequest()
                    continuation.yield(.requested)
                    try await controller.startSasVerification()
                    // Further `.readyForEmoji` / `.awaitingConfirmation` updates arrive
                    // via the SDK delegate (wired by `start()`). Stream stays open until
                    // the delegate's `didFinish` / `didCancel` finishes it.
                } catch {
                    continuation.yield(.cancelled(reason: error.localizedDescription))
                    continuation.finish()
                    await self.store.clearContinuation(for: requestID)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func confirmEmojiMatch(requestID: String) async throws {
        guard let controller = await store.controller(for: requestID) else {
            throw VerificationError.unknownRequest(requestID)
        }
        // Tell the SDK we approve. The SDK fires `didFinish` (or `didFail`/
        // `didCancel`) which `routeSasFinished` translates into `.verified`
        // on the open continuation. We deliberately do NOT yield `.verified`
        // here — that would lie to the caller about an SDK round-trip that
        // hasn't completed yet, and it's the security AND UX bug B1 surfaced
        // (a hypothetical "confirm before emoji compare" path would let the
        // user "verify" without the SDK signing anything).
        try await controller.approveVerification()
    }

    public func cancel(requestID: String, reason: String) async throws {
        guard let controller = await store.controller(for: requestID) else {
            // Nothing to cancel — drain any waiting continuation and exit. Idempotent
            // by design: cancel() is safe to call after the flow already ended.
            if let continuation = await store.continuation(for: requestID) {
                continuation.yield(.cancelled(reason: reason))
                continuation.finish()
            }
            await store.clearContinuation(for: requestID)
            return
        }
        // We yield `.cancelled` locally with the caller-supplied reason
        // before awaiting the SDK so the UI can dismiss immediately even if
        // the SDK's network round-trip is slow or the SDK silently drops the
        // delegate's `didCancel` (the SDK doesn't always re-fire `didCancel`
        // for a cancellation we initiated locally — its source-of-truth for
        // the user-facing reason is whatever string we pass in, not the
        // delegate's argless callback). The delegate's `didCancel` is still
        // wired so partner-side cancellations also reach the UI.
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
    /// under the new flow ID, marks it active, and yields a summary on the
    /// long-lived `incomingRequests()` stream so the
    /// `VerificationCenter` banner picks it up.
    func routeIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) async {
        let summary = VerificationRequestSummary(
            id: requestID,
            otherUserID: otherUserID,
            otherDeviceID: otherDeviceID,
            createdAt: Date()
        )
        await store.register(controller: controller, for: requestID)
        // The arriving request is now the active flow. The user accepting
        // the banner via `acceptIncoming(requestID:)` is what opens a
        // continuation against this entry; `setActiveFlowID` here means the
        // delegate's subsequent `didStartSasVerification` /
        // `didReceiveVerificationData` find the right continuation.
        await store.setActiveFlowID(requestID)
        if let cont = await store.incomingContinuation {
            cont.yield(summary)
        }
    }

    /// Routes the SDK delegate's `didStartSasVerification` callback. The flow
    /// has transitioned from request-acknowledged into SAS-active; no
    /// state change to surface to the UI yet (the next `didReceiveVerificationData`
    /// is what drives `.readyForEmoji([…])`). Kept as a routing entry point
    /// for symmetry with the rest of the delegate surface and to give tests
    /// a clear hook for asserting the lifecycle progressed.
    func routeSasStarted() async {
        // Intentionally no continuation yield: `.requested` was already
        // yielded by `acceptIncoming` / `startSAS` after we knew the SDK
        // had accepted the flow. The next visible-to-UI state is
        // `.readyForEmoji([…])` from `routeSasData`.
    }

    /// Routes the SDK delegate's `didReceiveVerificationData(SessionVerificationData)`.
    /// Only the `.emojis` variant is mapped — the `.decimals` variant exists
    /// in the SDK for legacy fallback but the spec mandates emoji SAS, so we
    /// surface that path as `.cancelled(reason:)` rather than silently
    /// rendering nothing.
    func routeSasData(_ data: SessionVerificationData) async {
        guard let active = await store.activeContinuation() else { return }
        switch data {
        case .emojis(let emojis, _):
            let mapped = emojis.map { SasEmoji(symbol: $0.symbol(), description: $0.description()) }
            active.continuation.yield(.readyForEmoji(mapped))
        case .decimals:
            // Phase 3 ships emoji-only SAS per spec §7.1. The SDK's decimal
            // fallback is reserved for very old peers; surface as a
            // cancellation so the UI dismisses cleanly rather than hanging.
            active.continuation.yield(.cancelled(reason: "Decimal SAS is not supported; use a peer that speaks emoji SAS."))
            active.continuation.finish()
            await store.clear(requestID: active.id)
        }
    }

    /// Routes the SDK delegate's `didFinish` callback. The SAS flow has
    /// completed successfully; the SDK has signed the cross-signing
    /// material on both sides. Yield `.verified` and clear the FlowStore
    /// entry for this flow.
    func routeSasFinished() async {
        guard let active = await store.activeContinuation() else { return }
        active.continuation.yield(.verified)
        active.continuation.finish()
        await store.clear(requestID: active.id)
    }

    /// Routes the SDK delegate's `didCancel` callback. Either side
    /// cancelled the flow. The SDK doesn't surface a reason on this
    /// callback, so we use a generic string — the local-cancel path
    /// (`cancel(requestID:reason:)`) yields its own reason before this
    /// fires, so this branch only matters for partner-initiated cancels.
    func routeSasCancelled() async {
        guard let active = await store.activeContinuation() else { return }
        active.continuation.yield(.cancelled(reason: "Verification cancelled"))
        active.continuation.finish()
        await store.clear(requestID: active.id)
    }

    /// Routes the SDK delegate's `didFail` callback. Surfaced as a
    /// `.cancelled(reason:)` with a fail-specific string so the UI
    /// distinguishes failure from explicit cancellation in error logs.
    func routeSasFailed() async {
        guard let active = await store.activeContinuation() else { return }
        active.continuation.yield(.cancelled(reason: "Verification failed"))
        active.continuation.finish()
        await store.clear(requestID: active.id)
    }
}

/// Errors surfaced by `VerificationServiceLive`. Equatable so tests can assert
/// the exact case without string-matching.
public enum VerificationError: Error, Equatable {
    case unknownRequest(String)
    case notConfigured
}

/// Production adapter — bridges our protocol to the real SDK type. The SDK's
/// `SessionVerificationController` already exposes the five methods we need with
/// matching signatures (verified against matrix-rust-components-swift v26.04.01),
/// so this is a pure forwarding shim.
final class LiveSessionVerificationController: SessionVerificationControlling, @unchecked Sendable {
    let inner: MatrixRustSDK.SessionVerificationController
    init(_ inner: MatrixRustSDK.SessionVerificationController) { self.inner = inner }

    func acceptVerificationRequest() async throws { try await inner.acceptVerificationRequest() }
    func startSasVerification()      async throws { try await inner.startSasVerification() }
    func approveVerification()       async throws { try await inner.approveVerification() }
    func declineVerification()       async throws { try await inner.declineVerification() }
    func cancelVerification()        async throws { try await inner.cancelVerification() }

    /// Convenience for `startSAS` when targeting the current user's other devices.
    /// Kept on the live adapter (not the protocol) because tests don't need this
    /// path — they exercise accept/confirm/cancel against `FakeSessionVerificationController`.
    func requestDeviceVerificationIfPossible() async throws {
        try await inner.requestDeviceVerification()
    }

    func requestUserVerificationIfPossible(userID: String) async throws {
        try await inner.requestUserVerification(userId: userID)
    }
}

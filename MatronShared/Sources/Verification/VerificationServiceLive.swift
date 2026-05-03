import Foundation
import MatrixRustSDK
import MatronModels
import MatronSync

/// Production implementation of `VerificationService`. Wraps the SDK's session
/// verification surface (`MatrixRustSDK.SessionVerificationController`) behind a
/// per-request controller cache so the UI can drive accept / confirm / cancel
/// against an `AsyncStream<SasFlowState>` without holding raw SDK delegate objects.
///
/// Concurrency model: the per-request `activeFlows` (controllers) and
/// `activeContinuations` (open SAS streams) are stored on a private `actor` so
/// reads + writes from accept / confirm / cancel are serialised. The class
/// itself is `@unchecked Sendable` because all mutation hops through the actor.
///
/// Test surface: callers can construct `VerificationServiceLive()` with no args
/// for unit tests that exercise the controller-cache flow against
/// `FakeSessionVerificationController`. The SDK-bound surfaces
/// (`isThisDeviceVerified`, `incomingRequests`, `startSAS`) require a live
/// `Client` and throw / return empty when the no-arg init was used; they are
/// integration-tested in Phase 7 against a real homeserver.
public final class VerificationServiceLive: VerificationService, @unchecked Sendable {
    private let provider: ClientProvider?
    private let session: UserSession?

    /// Per-request bookkeeping (controllers + open continuations) lives on its own
    /// actor so the cross-task accept/confirm/cancel mutations are serialised.
    private actor FlowStore {
        var controllers: [String: SessionVerificationControlling] = [:]
        var continuations: [String: AsyncStream<SasFlowState>.Continuation] = [:]

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
        }

        func snapshot() -> [String: SessionVerificationControlling] {
            controllers
        }
    }

    private let store = FlowStore()

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

    // MARK: - VerificationService

    public func isThisDeviceVerified() async throws -> Bool {
        guard let provider, let session else {
            throw VerificationError.notConfigured
        }
        let client = try await provider.client(for: session)
        return client.encryption().verificationState() == .verified
    }

    public func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        // Production wiring lands with `DeviceVerificationRequestObserver` in Task 4b.
        // Without a configured provider the stream finishes empty so unit tests can
        // safely poll it without hanging.
        AsyncStream { continuation in
            continuation.finish()
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
                    // wired up by `DeviceVerificationRequestObserver` (Task 4b).
                } catch {
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
                do {
                    try await controller.acceptVerificationRequest()
                    continuation.yield(.requested)
                    try await controller.startSasVerification()
                    // Further `.readyForEmoji` / `.awaitingConfirmation` updates arrive
                    // via the SDK delegate (wired in Task 4b). Stream stays open until
                    // confirmEmojiMatch / cancel finishes it.
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
        try await controller.approveVerification()
        if let continuation = await store.continuation(for: requestID) {
            continuation.yield(.verified)
            continuation.finish()
        }
        await store.clear(requestID: requestID)
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
        try await controller.cancelVerification()
        if let continuation = await store.continuation(for: requestID) {
            continuation.yield(.cancelled(reason: reason))
            continuation.finish()
        }
        await store.clear(requestID: requestID)
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

import Foundation
import MatrixRustSDK

/// Adapts SDK verification-request callbacks into events `VerificationServiceLive`
/// already consumes via its `register(controller:for:)` cache.
///
/// The shape is deliberately minimal — pure forwarding from a public entry point
/// (`handleIncomingRequest`) to a `IncomingVerificationListening` listener.
/// Keeps the SDK delegate boilerplate out of `VerificationServiceLive` and gives
/// us a fully testable seam.
public protocol IncomingVerificationListening: AnyObject, Sendable {
    func onUpdate(
        requestID: String,
        summary: VerificationRequestSummary,
        controller: SessionVerificationControlling
    )
}

/// Pure forwarding shim around the SDK's session-verification delegate. Owns no
/// state of its own. `LiveSessionVerificationDelegate` (below) is the production
/// adapter that the SDK actually calls; tests drive `handleIncomingRequest`
/// directly with a `FakeSessionVerificationController`.
public final class DeviceVerificationRequestObserver: @unchecked Sendable {
    private let listener: IncomingVerificationListening

    public init(listener: IncomingVerificationListening) {
        self.listener = listener
    }

    /// Pure entry point used by tests + the production delegate.
    /// - Parameters:
    ///   - requestID: the SDK's flow ID for this verification request. Used as
    ///     the summary's `id` so downstream consumers can correlate the
    ///     subsequent `acceptIncoming(requestID:)` / `cancel(requestID:)` calls.
    ///   - otherUserID: Matrix user ID of the requesting party.
    ///   - otherDeviceID: device ID of the requesting party (optional — the SDK
    ///     may surface verification requests without a device-level binding for
    ///     user-to-user verification).
    ///   - controller: the per-request SDK controller (wrapped in
    ///     `LiveSessionVerificationController` from the production delegate, or
    ///     a `FakeSessionVerificationController` from tests).
    public func handleIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) {
        let summary = VerificationRequestSummary(
            id: requestID,
            otherUserID: otherUserID,
            otherDeviceID: otherDeviceID,
            createdAt: Date()
        )
        listener.onUpdate(requestID: requestID, summary: summary, controller: controller)
    }
}

/// Routing seam between the SDK delegate and the service that owns the
/// FlowStore + open continuations. `VerificationServiceLive` conforms to
/// this in production; tests substitute a fake to assert the delegate
/// translates each SDK callback into the correct routing entry point.
///
/// Each entry point is `async` so the delegate hops onto the FlowStore actor
/// rather than spinning its own thread state. Held weakly by the delegate
/// so the SDK's strong reference (via the callback handle map) doesn't
/// pin the service after `signOut()` clears the AppDependencies cache.
protocol SessionVerificationFlowRouting: AnyObject, Sendable {
    func routeIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) async
    func routeSasStarted() async
    func routeSasData(_ data: SessionVerificationData) async
    func routeSasFinished() async
    func routeSasCancelled() async
    func routeSasFailed() async
}

/// Production-side delegate that the SDK calls. Translates each
/// `SessionVerificationControllerDelegate` callback into the matching
/// `routeSas…` entry point on the live `VerificationServiceLive`.
///
/// The SDK delegate doesn't hand back a controller per request — the same
/// `SessionVerificationController` is reused across the session — so we wrap
/// the shared controller as `LiveSessionVerificationController` and forward
/// alongside the request summary so the listener has a working SDK handle.
///
/// Concurrency: SDK callbacks come in on the SDK's own callback thread (via
/// uniffi's vtable). All bodies hop into the router's actor via `Task { await … }`.
/// `router` is `weak` so the SDK's callback-handle retention doesn't keep
/// the service alive past `signOut()`.
final class LiveSessionVerificationDelegate: SessionVerificationControllerDelegate, @unchecked Sendable {
    private weak var router: (any SessionVerificationFlowRouting)?
    private let sharedController: MatrixRustSDK.SessionVerificationController

    init(router: any SessionVerificationFlowRouting, sharedController: MatrixRustSDK.SessionVerificationController) {
        self.router = router
        self.sharedController = sharedController
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        guard let router else { return }
        // `deviceId` is non-optional in v26.04.01's `SessionVerificationRequestDetails`,
        // but the upstream protocol surface accepts `String?` so a future SDK
        // change to optional won't churn the router contract. An empty deviceId
        // is treated as "no device binding" because the only way to express that
        // distinction in the current SDK shape is the empty string.
        let deviceID = details.deviceId.isEmpty ? nil : details.deviceId
        let wrapped = LiveSessionVerificationController(sharedController)
        Task {
            await router.routeIncomingRequest(
                requestID: details.flowId,
                otherUserID: details.senderProfile.userId,
                otherDeviceID: deviceID,
                controller: wrapped
            )
        }
    }

    /// Fires after the SDK accepts the SAS handshake and the underlying
    /// channel is established. We've already yielded `.requested` on the
    /// open continuation from `acceptIncoming` / `startSAS`, so this is a
    /// quiet transition — the next visible state is `.readyForEmoji`
    /// from `didReceiveVerificationData`.
    func didAcceptVerificationRequest() {
        // The router doesn't expose a `didAccept` entry point — the next
        // SDK callback (`didStartSasVerification`) is what marks the SAS
        // flow as live. Keeping this body empty (rather than routing to a
        // no-op) keeps the routing surface focused on user-visible state.
    }

    func didStartSasVerification() {
        guard let router else { return }
        Task { await router.routeSasStarted() }
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        guard let router else { return }
        Task { await router.routeSasData(data) }
    }

    func didFail() {
        guard let router else { return }
        Task { await router.routeSasFailed() }
    }

    func didCancel() {
        guard let router else { return }
        Task { await router.routeSasCancelled() }
    }

    func didFinish() {
        guard let router else { return }
        Task { await router.routeSasFinished() }
    }
}

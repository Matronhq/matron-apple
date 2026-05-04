import Foundation
import MatrixRustSDK
import os

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
/// state of its own. `WeakSessionVerificationControllerProxy` (below) is the
/// production adapter that the SDK actually calls; tests drive
/// `handleIncomingRequest` directly with a `FakeSessionVerificationController`.
public final class DeviceVerificationRequestObserver: @unchecked Sendable {
    private let listener: IncomingVerificationListening

    public init(listener: IncomingVerificationListening) {
        self.listener = listener
    }

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
///
/// Wave 7 added `routeAcceptedVerificationRequest()`. The prior shape made
/// `didAcceptVerificationRequest` a no-op on the delegate; that was correct
/// only when both sides were forced to manually advance state via a
/// "Start verification" button click (Element X's UX). Our flow auto-
/// advances, so the responder side issues `startSasVerification()` from
/// inside this delegate callback. The branch on responder vs requester
/// lives in `VerificationServiceLive.routeAcceptedVerificationRequest`.
protocol SessionVerificationFlowRouting: AnyObject, Sendable {
    func routeIncomingRequest(
        requestID: String,
        otherUserID: String,
        otherDeviceID: String?,
        controller: SessionVerificationControlling
    ) async
    func routeAcceptedVerificationRequest() async
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
/// Wave 7 — `WeakSessionVerificationControllerProxy`:
///
/// Mirrors Element X iOS's
/// `WeakSessionVerificationControllerProxy` (see
/// `ElementX/Sources/Services/SessionVerification/SessionVerificationControllerProxy.swift`).
/// The SDK retains the delegate strongly via its callback-handle map; if
/// the delegate held a strong back-reference to the routing service that
/// owns the SDK controller, we'd have a retain cycle. Holding `router`
/// weakly breaks the cycle — `signOut()` can drop the
/// `VerificationServiceLive` instance and the SDK's now-orphaned delegate
/// no-ops cleanly when the next callback arrives.
///
/// `sharedController` is held strongly. That's safe because the
/// retain-cycle break is on the OTHER edge (delegate → router weak); the
/// SDK controller doesn't hold a strong reference back to its delegate
/// in a way Swift's ARC can see (uniffi's callback handle map is a Rust
/// data structure, not part of the Swift retain graph). Element X follows
/// the same shape — see `SessionVerificationControllerProxy.swift`.
///
/// Concurrency: SDK callbacks come in on the SDK's own callback thread (via
/// uniffi's vtable). All bodies hop into the router's actor via `Task { await … }`.
final class WeakSessionVerificationControllerProxy: SessionVerificationControllerDelegate, @unchecked Sendable {
    private weak var router: (any SessionVerificationFlowRouting)?
    private let sharedController: MatrixRustSDK.SessionVerificationController

    init(router: any SessionVerificationFlowRouting, sharedController: MatrixRustSDK.SessionVerificationController) {
        self.router = router
        self.sharedController = sharedController
    }

    // MARK: - SessionVerificationControllerDelegate

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        Self.logger.notice("SDK→didReceiveVerificationRequest: flowId=\(details.flowId, privacy: .public) from=\(details.senderProfile.userId, privacy: .public)")
        guard let router else {
            Self.logger.error("SDK→didReceiveVerificationRequest: router is nil — DROPPED")
            return
        }
        let deviceID = details.deviceId.isEmpty ? nil : details.deviceId
        let wrapped = LiveSessionVerificationController(sharedController)
        Task { [weak router] in
            guard let router else { return }
            await router.routeIncomingRequest(
                requestID: details.flowId,
                otherUserID: details.senderProfile.userId,
                otherDeviceID: deviceID,
                controller: wrapped
            )
        }
    }

    /// Wave 7 bug #5 fix: this used to be a silent no-op. It now routes
    /// to the service so the responder side can issue
    /// `startSasVerification()` (the requester side is excluded inside
    /// `routeAcceptedVerificationRequest` based on the role recorded in
    /// the FlowStore).
    func didAcceptVerificationRequest() {
        Self.logger.notice("SDK→didAcceptVerificationRequest")
        guard let router else {
            Self.logger.error("SDK→didAcceptVerificationRequest: router is nil — DROPPED")
            return
        }
        Task { await router.routeAcceptedVerificationRequest() }
    }

    func didStartSasVerification() {
        Self.logger.notice("SDK→didStartSasVerification")
        guard let router else {
            Self.logger.error("SDK→didStartSasVerification: router is nil — DROPPED")
            return
        }
        Task { await router.routeSasStarted() }
    }

    func didReceiveVerificationData(data: SessionVerificationData) {
        Self.logger.notice("SDK→didReceiveVerificationData: \(String(describing: data), privacy: .public)")
        guard let router else {
            Self.logger.error("SDK→didReceiveVerificationData: router is nil — DROPPED")
            return
        }
        Task { await router.routeSasData(data) }
    }

    func didFail() {
        Self.logger.notice("SDK→didFail")
        guard let router else {
            Self.logger.error("SDK→didFail: router is nil — DROPPED")
            return
        }
        Task { await router.routeSasFailed() }
    }

    func didCancel() {
        Self.logger.notice("SDK→didCancel")
        guard let router else {
            Self.logger.error("SDK→didCancel: router is nil — DROPPED")
            return
        }
        Task { await router.routeSasCancelled() }
    }

    func didFinish() {
        Self.logger.notice("SDK→didFinish")
        guard let router else {
            Self.logger.error("SDK→didFinish: router is nil — DROPPED")
            return
        }
        Task { await router.routeSasFinished() }
    }

    static let logger = os.Logger(subsystem: "chat.matron", category: "verification-delegate")
}

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

/// Production-side delegate that the SDK calls. Translates
/// `SessionVerificationControllerDelegate.didReceiveVerificationRequest`
/// (the only callback that surfaces an incoming request in v26.04.01) into the
/// observer's `handleIncomingRequest` shape.
///
/// The SDK delegate doesn't hand back a controller per request — the same
/// `SessionVerificationController` is reused across the session — so we wrap
/// the shared controller as `LiveSessionVerificationController` and forward.
/// The remaining lifecycle callbacks (`didStartSasVerification`,
/// `didReceiveVerificationData`, `didFinish`, `didCancel`, `didFail`) drive
/// `SasFlowState` transitions on streams already opened by
/// `VerificationServiceLive.acceptIncoming` / `startSAS`; that wiring lands
/// with the SAS-state listener in a later task — kept out of scope here so
/// this commit stays focused on the request-arrival adapter.
final class LiveSessionVerificationDelegate: SessionVerificationControllerDelegate, @unchecked Sendable {
    private let observer: DeviceVerificationRequestObserver
    private let sharedController: MatrixRustSDK.SessionVerificationController

    init(observer: DeviceVerificationRequestObserver, sharedController: MatrixRustSDK.SessionVerificationController) {
        self.observer = observer
        self.sharedController = sharedController
    }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        observer.handleIncomingRequest(
            requestID: details.flowId,
            otherUserID: details.senderProfile.userId,
            otherDeviceID: details.deviceId,
            controller: LiveSessionVerificationController(sharedController)
        )
    }

    // SAS-flow callbacks — wiring them into the open SAS continuation lands with
    // the dedicated SAS state listener task. Implemented as no-ops here so this
    // commit stays scoped to the request-arrival adapter.
    func didAcceptVerificationRequest()                              {}
    func didStartSasVerification()                                   {}
    func didReceiveVerificationData(data: SessionVerificationData)   {}
    func didFail()                                                   {}
    func didCancel()                                                 {}
    func didFinish()                                                 {}
}

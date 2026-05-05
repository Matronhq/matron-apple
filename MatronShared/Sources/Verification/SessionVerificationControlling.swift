import Foundation

/// Protocol abstraction over `MatrixRustSDK.SessionVerificationController`.
///
/// Lets `VerificationServiceLive` be unit-tested with a `FakeSessionVerificationController`
/// instead of needing a live SDK `Client`. Production code wraps the real SDK type with
/// `LiveSessionVerificationController` (defined alongside `VerificationServiceLive`).
///
/// The methods mirror the SDK surface used by SAS flows in matrix-rust-components-swift
/// v26.04.01: register an inbound request, accept it, transition into SAS, approve /
/// decline the SAS string, cancel the flow.
public protocol SessionVerificationControlling: AnyObject, Sendable {
    /// Required on the responder side BEFORE `acceptVerificationRequest()`.
    /// Sets the SDK's active flow so `acceptVerificationRequest()` knows
    /// which incoming request to issue `m.key.verification.ready` for.
    /// Without this call, `acceptVerificationRequest()` silently no-ops
    /// (returns OK without queuing any outgoing event), which strands the
    /// requester at "waiting for SAS emojis" indefinitely. Element X iOS
    /// calls this from
    /// `SessionVerificationControllerProxy.acknowledgeVerificationRequest`
    /// (`ElementX/Sources/Services/SessionVerification/SessionVerificationControllerProxy.swift:71-80`).
    func acknowledgeVerificationRequest(senderId: String, flowId: String) async throws
    func acceptVerificationRequest() async throws
    func startSasVerification() async throws
    func approveVerification() async throws
    func declineVerification() async throws
    func cancelVerification() async throws
}

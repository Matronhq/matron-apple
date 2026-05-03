import Foundation

/// Protocol abstraction over `MatrixRustSDK.SessionVerificationController`.
///
/// Lets `VerificationServiceLive` be unit-tested with a `FakeSessionVerificationController`
/// instead of needing a live SDK `Client`. Production code wraps the real SDK type with
/// `LiveSessionVerificationController` (defined alongside `VerificationServiceLive`).
///
/// The five methods mirror the SDK surface used by SAS flows in matrix-rust-components-swift
/// v26.04.01: accept the request, transition into SAS, approve / decline the SAS string,
/// cancel the flow.
public protocol SessionVerificationControlling: AnyObject, Sendable {
    func acceptVerificationRequest() async throws
    func startSasVerification() async throws
    func approveVerification() async throws
    func declineVerification() async throws
    func cancelVerification() async throws
}

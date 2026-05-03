import Foundation

/// High-level interface over the SDK's verification machinery. Wraps SAS
/// (Short Authentication String) device verification flows so callers can
/// observe transitions as a stream of `SasFlowState` values without holding
/// raw SDK callback objects.
///
/// `VerificationServiceLive` is the production implementation (Task 4). For
/// unit tests, prefer `FakeVerificationService` (in `Tests/VerificationTests/`)
/// which yields a scripted state sequence.
public protocol VerificationService: Sendable {
    /// True if this device's signing keys are present on the server and have
    /// been signed by the user's master cross-signing key. Used by the
    /// onboarding banner to decide whether to prompt the user.
    func isThisDeviceVerified() async throws -> Bool

    /// True if the cross-signing identity for `matrixID` is verified by this
    /// account. Drives the per-bot inline banner shown above the chat
    /// timeline (spec §7.3, §7.5). Returns `false` when the user identity
    /// can't be looked up (e.g. unknown user, network unavailable) so the
    /// banner errs on the side of prompting verification — matches the
    /// "nothing auto-trusted" trust posture from §7.5.
    func isUserVerified(matrixID: String) async throws -> Bool

    /// Emits incoming verification requests originating from another device
    /// (or a bot) of the same user. The stream terminates when the service
    /// is cancelled. Callers should drive it from a child task scoped to
    /// the view's lifetime.
    func incomingRequests() -> AsyncStream<VerificationRequestSummary>

    /// Begins a SAS verification with the given user/device. The returned
    /// stream emits `SasFlowState` transitions and finishes when the flow
    /// reaches `.verified` or `.cancelled`.
    /// - Parameter deviceID: optional. If `nil`, the SDK targets all of
    ///   the user's devices.
    func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState>

    /// Accepts an incoming verification request previously surfaced via
    /// `incomingRequests()` and starts the SAS flow against it.
    func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState>

    /// Confirms the emoji set displayed to the user matches the one on the
    /// other device. After this resolves successfully, the stream returned
    /// from `startSAS`/`acceptIncoming` advances toward `.verified`.
    func confirmEmojiMatch(requestID: String) async throws

    /// Cancels the flow with a free-form reason (e.g. "user-cancelled",
    /// "mismatch"). Idempotent — safe to call after the flow already ended.
    func cancel(requestID: String, reason: String) async throws
}

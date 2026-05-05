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

    /// Tri-state trust check for the per-bot inline banner shown above the
    /// chat timeline (spec §7.3, §7.5). Returns:
    ///   * `.verified`   — SDK has the identity AND it's cross-signed.
    ///   * `.unverified` — SDK has the identity, but it's NOT cross-signed.
    ///   * `.unknown`    — SDK does not yet have the identity in its local
    ///                     crypto store (cold-start; sliding-sync hasn't
    ///                     warmed up `/keys/query` yet).
    ///
    /// The `.unknown` arm is what makes this tri-state instead of `Bool`:
    /// collapsing "identity not loaded" into "unverified" caused the
    /// per-bot banner to flash on every cold-start chat open. Callers
    /// hide the banner on `.unknown` and re-evaluate on the next
    /// sliding-sync tick — matches §7.5's "nothing auto-trusted" posture
    /// without lying about an identity we haven't queried yet.
    func isUserVerified(matrixID: String) async throws -> UserVerificationResult

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

    /// True if the user has another already-verified device that this
    /// device could SAS-verify against. Used by the chat-list verify
    /// chooser to decide whether to enable the "Verify with another
    /// device" option — if there's no other verified peer (e.g. both
    /// devices' SDK stores got wiped on re-login), SAS would hang
    /// indefinitely waiting for a partner that doesn't exist, and
    /// the user needs to use their recovery key instead.
    ///
    /// Wraps matrix-rust-sdk's
    /// `Encryption.hasDevicesToVerifyAgainst()` (the device must be
    /// signed by the user's cross-signing key, must have an identity,
    /// and must not be a dehydrated device).
    func hasOtherVerifiedDevices() async throws -> Bool

    /// Emits the request ID of an inbound verification flow whose
    /// SDK-side state transitioned to cancelled while no local SAS
    /// sheet was observing it (e.g. the partner cancelled before
    /// our user clicked the banner, or the SDK's internal
    /// inactivity timeout fired). Lets the chat-list banner
    /// consumer drain its `pending` list so a stale "Verify this
    /// device" banner doesn't outlive the underlying flow.
    ///
    /// Distinct from per-SAS cancellation already surfaced via
    /// `acceptIncoming(requestID:)`'s stream emitting `.cancelled` —
    /// that path requires a continuation to be open. This stream
    /// covers the no-continuation case.
    func cancelledRequests() -> AsyncStream<String>
}

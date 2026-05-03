import Foundation
import MatronVerification

/// Cross-platform view-model for the SAS (Short Authentication String)
/// emoji-compare verification flow (spec §7.1). Lives in `MatronViewModels`
/// so iOS (`SasView`) and macOS (`MacSasView`) consume the same state machine.
///
/// The VM is a thin adapter over the `AsyncStream<SasFlowState>` returned by
/// `VerificationService.startSAS` (or `acceptIncoming`): each yielded state
/// becomes the next value of `state` for SwiftUI to render.
///
/// Confirm / cancel actions route back to the service via injected closures
/// so this type is testable standalone in `MatronViewModels` without dragging
/// in an SDK or fake. Production callers wire `confirm` to
/// `VerificationService.confirmEmojiMatch(requestID:)` and `cancel` to
/// `VerificationService.cancel(requestID:reason:)`.
///
/// Lifecycle: Swift 6 strict concurrency forbids a `@MainActor deinit`
/// reaching into isolated state, so there's no auto-cleanup. The stream is
/// owned by the service that produced it; when the producer finishes (e.g.
/// the live impl on `.verified` / `.cancelled`) the `for await` loop falls
/// through and `observe()` returns. Views call `observe()` from `.task(id:)`
/// (which SwiftUI auto-cancels on disappear) — no explicit cancel needed.
@Observable
@MainActor
public final class SasViewModel {
    public private(set) var state: SasFlowState = .idle
    public let requestID: String

    private let stream: AsyncStream<SasFlowState>
    private let confirmAction: () async throws -> Void
    private let cancelAction: (String) async throws -> Void

    /// Re-entrancy guard: `observe()` must consume the stream exactly once
    /// even if SwiftUI re-fires `.task(id:)` (e.g. on view re-presentation
    /// or on a state-only re-render that doesn't change `requestID`).
    /// The second call early-returns; the first call's `for await` keeps
    /// running until the producer finishes.
    private var isObserving: Bool = false

    public init(
        stream: AsyncStream<SasFlowState>,
        requestID: String,
        confirm: @escaping () async throws -> Void,
        cancel: @escaping (String) async throws -> Void
    ) {
        self.stream = stream
        self.requestID = requestID
        self.confirmAction = confirm
        self.cancelAction = cancel
    }

    /// Drains the SAS state stream into `state`. Idempotent: a second call
    /// while the first is still running (or after it finished) is a no-op.
    public func observe() async {
        guard !isObserving else { return }
        isObserving = true
        for await new in stream {
            state = new
        }
    }

    /// User confirmed the emoji set matches the other device. Errors thrown
    /// by the underlying service are intentionally swallowed at this layer
    /// — the stream will surface the resulting `.cancelled(reason:)` if the
    /// confirm fails, which is how the UI learns about the failure. Use
    /// `try? await` so we don't propagate up into a `Task { ... }` body
    /// that would otherwise need a do/catch.
    public func confirm() async {
        try? await confirmAction()
    }

    /// User said the emojis don't match (or backed out). Same error-handling
    /// rationale as `confirm()`: the resulting state transition arrives via
    /// the stream.
    public func cancel(reason: String = "User cancelled") async {
        try? await cancelAction(reason)
    }
}

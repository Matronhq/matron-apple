import Foundation
import MatronVerification

/// Cross-platform orchestrator for incoming verification requests (spec
/// §7.1, §5.9). Drives the verification banner that the chat-list (iOS)
/// or sidebar (Mac) presents — observes
/// `VerificationService.incomingRequests()` and exposes the resulting
/// summaries as an `@Observable` array so SwiftUI re-renders on append /
/// removal.
///
/// Lives in `MatronViewModels` so iOS (`Matron/Features/Verification/`)
/// and macOS (`MatronMac/Features/Verification/`) consume the same
/// orchestrator instance — Task 9 wires it on iOS, Task 9b on Mac.
///
/// Lifecycle: `start()` spins up a child observation task that drains the
/// service's request stream into `pending`. `stop()` cancels that task.
/// Swift 6 strict concurrency forbids a `@MainActor deinit` reaching into
/// isolated state, so callers must invoke `stop()` explicitly from
/// `View.onDisappear` (mirrors the `ChatListViewModel.cancel()` pattern
/// added in Phase 2). `start()` is idempotent — re-firing it cancels the
/// prior observation task and starts fresh, so a SwiftUI view remount
/// that re-calls `start()` won't leak the previous task.
@Observable
@MainActor
public final class VerificationCenter {
    /// Pending incoming verification requests, in arrival order. The chat
    /// list / sidebar renders one banner per entry. Mutated only on the
    /// main actor (the observation task hops back via `await MainActor.run`
    /// when it appends).
    public private(set) var pending: [VerificationRequestSummary] = []

    private let service: VerificationService
    private var observationTask: Task<Void, Never>?

    public init(service: VerificationService) {
        self.service = service
    }

    /// Begin observing the service's incoming-request stream. Idempotent:
    /// a second call cancels the prior task and starts a new one, so a
    /// view remount that re-fires `start()` doesn't leak the previous
    /// observation. Dedupes by `summary.id` so a service that re-yields
    /// the same request (e.g. on stream reconnect) doesn't render the
    /// banner twice.
    public func start() {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            // Capture the stream before entering the loop so a
            // hot-reload that briefly drops `self` from the closure
            // doesn't wedge on a re-evaluation.
            let stream = await self.service.incomingRequests()
            for await summary in stream {
                if Task.isCancelled { break }
                await MainActor.run {
                    if !self.pending.contains(where: { $0.id == summary.id }) {
                        self.pending.append(summary)
                    }
                }
            }
        }
    }

    /// Cancel the observation task. Safe to call without a prior `start()`
    /// — the optional task is `nil` in that case and `cancel()` no-ops.
    /// Callers wire this to `View.onDisappear` so the long-lived stream
    /// doesn't outlive the host view.
    public func stop() {
        observationTask?.cancel()
        observationTask = nil
    }

    /// Dismissing a banner must also cancel the underlying SDK
    /// verification request, otherwise the other side keeps the request
    /// open forever and the user sees a stale "waiting" UI on the
    /// partner device. Cancel-then-remove ordering ensures the SDK call
    /// still happens even when an error from the service would
    /// short-circuit the local removal.
    ///
    /// `try?` is intentional — `cancel(requestID:reason:)` is documented
    /// idempotent on the live impl (already-cancelled requests no-op).
    /// Surfacing the error here would block local removal, leaving a
    /// stale banner the user can't dismiss; that's worse than swallowing
    /// the error since the partner device's "stale waiting" UI is the
    /// only observable consequence and they can dismiss from their side.
    public func dismiss(_ summary: VerificationRequestSummary) async {
        try? await service.cancel(requestID: summary.id, reason: "User dismissed")
        pending.removeAll { $0.id == summary.id }
    }

    #if DEBUG
    /// Test seam — lets unit tests pre-populate `pending` without driving
    /// the stream. Production code only ever appends via the observation
    /// task. Gated behind `#if DEBUG` so release builds don't expose the
    /// mutation surface.
    public func injectPending(_ summary: VerificationRequestSummary) {
        pending.append(summary)
    }
    #endif
}

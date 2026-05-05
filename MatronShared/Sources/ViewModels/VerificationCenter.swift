import Foundation
import os
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
/// added in Phase 2). `start()` is idempotent — Wave 5 bugbot #4 made
/// it a no-op when an observation task is already running (was: cancel
/// + restart). Two call sites fire `start()` on cold-launch — the host's
/// `.task(id: session.userID)` AND the chat-list's `.onAppear` — and
/// whichever fired second under the prior shape would cancel the first's
/// observation task, silently breaking the incoming-request stream.
/// Both call sites stay (defence in depth: `.task(id:)` keys on session
/// change; `.onAppear` recovers if the parent task somehow didn't fire,
/// e.g. in a preview or test bypass) — first one wins, the second is a
/// safe no-op.
@Observable
@MainActor
public final class VerificationCenter {
    /// Pending incoming verification requests, in arrival order. The chat
    /// list / sidebar renders one banner per entry. Mutated only on the
    /// main actor (the observation task hops back via `await MainActor.run`
    /// when it appends).
    public private(set) var pending: [VerificationRequestSummary] = []

    /// Logger for the dismiss-cancel failure path (Wave 4 expert-QA #5).
    /// `try?` used to silently swallow `cancel(...)` errors here; the
    /// next time SDK cancels fail to deliver — in particular Phase 4
    /// push-flow debugging when a cancel races a notification dismiss
    /// — we want a breadcrumb in the unified log instead of nothing.
    /// `subsystem: "chat.matron"` matches the existing logger in
    /// `MarkdownText` so all app-side logs share the same filter.
    private static let logger = os.Logger(subsystem: "chat.matron", category: "verification")

    /// The underlying service. Exposed so banner-presented sheets can route
    /// `acceptIncoming(requestID:)` / `confirm` / `cancel` calls through the
    /// SAME instance whose FlowStore registered the incoming request —
    /// building a fresh `VerificationServiceLive` would hit an empty
    /// FlowStore and immediately yield `.cancelled(reason: "Unknown
    /// request: …")`. Bugbot caught this on the iOS banner.
    public let service: VerificationService
    private var observationTask: Task<Void, Never>?
    /// Parallel observation task for `service.cancelledRequests()` — drains
    /// `pending` when the SDK fires a cancel for a flow that had no SAS
    /// sheet observing it (e.g. partner cancelled before the user clicked
    /// our banner). Without this the banner outlives the underlying flow
    /// and the user is left tapping a Verify button that opens a sheet
    /// which immediately closes (the cancel propagated server-side
    /// already) or hangs (worse, depending on SDK state).
    private var cancelObservationTask: Task<Void, Never>?

    public init(service: VerificationService) {
        self.service = service
    }

    /// Begin observing the service's incoming-request stream. Idempotent:
    /// a second call while an observation task is already running is a
    /// safe no-op (Wave 5 bugbot #4). Two call sites fire `start()` on
    /// cold-launch — the host's `.task(id: session.userID)` AND the
    /// chat-list view's `.onAppear` — and the prior cancel-then-restart
    /// shape meant whichever fired second would cancel the first's
    /// observation, silently breaking the incoming-request stream. The
    /// first caller wins; a view remount that re-fires `start()` doesn't
    /// double-observe (no leak) and doesn't replace the running task
    /// (no race). Dedupes by `summary.id` so a service that re-yields
    /// the same request (e.g. on stream reconnect) doesn't render the
    /// banner twice.
    public func start() {
        if observationTask != nil { return }
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
        if cancelObservationTask == nil {
            cancelObservationTask = Task { [weak self] in
                guard let self else { return }
                let stream = await self.service.cancelledRequests()
                for await flowID in stream {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        self.pending.removeAll { $0.id == flowID }
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
        cancelObservationTask?.cancel()
        cancelObservationTask = nil
    }

    /// Dismissing a banner must also cancel the underlying SDK
    /// verification request, otherwise the other side keeps the request
    /// open forever and the user sees a stale "waiting" UI on the
    /// partner device. Cancel-then-remove ordering ensures the SDK call
    /// still happens even when an error from the service would
    /// short-circuit the local removal.
    ///
    /// Cancel errors are caught locally (not propagated) because
    /// `cancel(requestID:reason:)` is documented idempotent on the live
    /// impl (already-cancelled requests no-op). Surfacing the error
    /// here would block local removal, leaving a stale banner the user
    /// can't dismiss; that's worse than swallowing the error since the
    /// partner device's "stale waiting" UI is the only observable
    /// consequence and they can dismiss from their side.
    ///
    /// Wave 4 expert-QA #5: log the failure at `.error` so Phase 4 push
    /// debugging will know when SDK cancels failed to deliver. The
    /// `try?` silent-swallow used to make this branch invisible.
    /// Drain a flow from `pending` after it reached `.verified` —
    /// counterpart to `dismiss(_:)` minus the SDK cancel call. The SAS
    /// sheet's `onFinished` callback fires when the per-flow stream
    /// yields `.verified`, at which point the SDK has already completed
    /// the verification and a `cancelVerification()` call would be both
    /// nonsensical and potentially trip the SDK's "verification request
    /// missing" path. So this method just removes the entry locally so
    /// the sidebar banner clears.
    ///
    /// Without this, the user finishes a successful SAS round trip but
    /// the chat-list sidebar still shows "Verify this device — Verify"
    /// for the now-completed request until they manually dismiss it
    /// (which would attempt an SDK cancel against a finished flow).
    public func markCompleted(_ summary: VerificationRequestSummary) {
        pending.removeAll { $0.id == summary.id }
    }

    public func dismiss(_ summary: VerificationRequestSummary) async {
        do {
            try await service.cancel(requestID: summary.id, reason: "User dismissed")
        } catch {
            // Phase 4 push debugging will need to know when SDK cancels
            // failed to deliver — a partner-device stale-waiting UI
            // pairs with a logged cancel-fail here. `.public` privacy
            // is fine: the error message is SDK-bookkeeping text, no
            // user-content / token leakage.
            Self.logger.error("VerificationCenter.dismiss: cancel failed for requestID=\(summary.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
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

    /// Test seam — exposes whether the observation task is currently
    /// installed. Used by Wave 5 bugbot #4's idempotency test to assert
    /// that a second `start()` does not replace the running task.
    /// Gated behind `#if DEBUG` so release builds don't leak the surface.
    public var hasObservationTask: Bool { observationTask != nil }
    #endif
}

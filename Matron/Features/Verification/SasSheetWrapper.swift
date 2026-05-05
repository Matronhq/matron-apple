import SwiftUI
import MatronVerification
import MatronViewModels

/// Per-present SAS sheet wrapper (PR #3 review #1). Eight near-identical
/// `@State SasViewModel?` + `.task(id: requestID) { … = SasViewModel(stream:
/// …, …) }` wrappers were generated across iOS + Mac, differing only in
/// stream factory, title, and host platform's `SasView`. This is the iOS
/// version, parameterised by the stream factory + title; one Mac-side twin
/// lives at `MatronMac/Features/Verification/MacSasSheetWrapper.swift`.
///
/// **Wave 5 bugbot #2** (preserved behaviour). Earlier waves built the VM
/// + opened the stream in `init` and seeded it via
/// `_viewModel = State(initialValue: …)`. SwiftUI keeps the `@State`-stored
/// VM stable across re-inits at the same view-identity, BUT the right-hand
/// side of `_viewModel = State(initialValue: …)` still EVALUATES on every
/// `init` — so the stream-factory call fired on every parent body
/// re-render. Each call hits `FlowStore.setContinuation` (Wave 2 / M3),
/// which drains the prior continuation with `.cancelled("Replaced by new
/// flow")`. The `@State`-preserved VM is then observing a now-terminated
/// stream and the user sees an unexpected cancellation any time the
/// parent re-renders.
///
/// Shape kept: VM is `@State private var viewModel: SasViewModel?` (nil
/// until the side-effect runs), and the stream factory is invoked from
/// `.task(id: requestID)` — which SwiftUI guarantees to fire exactly once
/// per identity value, not on every body re-eval. The `guard viewModel ==
/// nil` is belt-and-suspenders against SwiftUI invoking the id-keyed task
/// once on cold-init AND once on first body settle.
struct SasSheetWrapper: View {
    let service: VerificationService
    let requestID: String
    let title: String
    let streamFactory: (VerificationService) -> AsyncStream<SasFlowState>
    let onFinished: () -> Void
    let onCancelled: () -> Void

    @State private var viewModel: SasViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                SasView(
                    viewModel: vm,
                    title: title,
                    onFinished: onFinished,
                    onCancelled: onCancelled
                )
            } else {
                ProgressView("Starting verification…")
            }
        }
        .task(id: requestID) {
            guard viewModel == nil else { return }
            let stream = streamFactory(service)
            viewModel = SasViewModel(
                stream: stream,
                requestID: requestID,
                confirm: { try await service.confirmEmojiMatch(requestID: requestID) },
                cancel: { reason in try await service.cancel(requestID: requestID, reason: reason) }
            )
        }
    }
}

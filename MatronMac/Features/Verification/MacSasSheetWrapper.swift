#if os(macOS)
import SwiftUI
import MatronVerification
import MatronViewModels

/// Per-present SAS sheet wrapper (PR #3 review #1). Mac twin of
/// `SasSheetWrapper` — same shape, renders `MacSasView` instead of
/// `SasView`. See the iOS file for the Wave 5 bugbot #2 rationale (the
/// prior `init`-side stream creation fired on every parent body
/// re-render and silently cancelled the active continuation via Wave 2 /
/// M3's "Replaced by new flow" drain).
struct MacSasSheetWrapper: View {
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
                MacSasView(
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
#endif

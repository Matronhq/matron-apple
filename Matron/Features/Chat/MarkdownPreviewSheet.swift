import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// The iPhone's markdown attachment preview (shared spec "markdown
/// preview"): a full-height sheet around `MarkdownPreviewView`, fetching
/// the file through the app's authenticated media path. Presented by the
/// chat and the item thread in place of the download a tap on a `.md` file
/// used to start.
struct MarkdownPreviewSheet: View {
    let request: MarkdownPreviewRequest
    let media: any MediaService
    /// Today's download path for this file (the share/QuickLook sheet),
    /// offered when the preview can't show it.
    var onDownload: (() -> Void)?
    let onClose: () -> Void

    @State private var model = MarkdownPreviewModel()

    var body: some View {
        MarkdownPreviewView(
            name: request.name,
            phase: model.phase,
            showsSource: $model.showsSource,
            shareURL: model.shareURL,
            onRetry: { model.retry() },
            onDownload: onDownload,
            onClose: onClose
        )
        .task(id: request) {
            let media = media
            model.open(request, fetch: { await media.fetchOutcome(mxcURL: $0) })
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

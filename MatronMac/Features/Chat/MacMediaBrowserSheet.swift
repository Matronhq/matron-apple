import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronViewModels

/// Mac presentation of the per-chat media & links browser. Owns the
/// `MediaBrowserViewModel`; taps route into the same paths the timeline
/// uses — images to `AttachmentFullscreenViewer`, files through
/// `ChatViewModel.writeTempFile` → `NSWorkspace.open`, links to the
/// default browser.
struct MacMediaBrowserSheet: View {
    let chatViewModel: ChatViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MediaBrowserViewModel?
    @State private var imagePreview: Preview?
    /// Media URLs whose full-size fetch is currently in flight — guards
    /// `openImage` against re-entrant taps stacking overlapping downloads,
    /// and drives `MediaCell.isLoading`'s spinner. Kept local to the sheet
    /// (not `ChatViewModel`) because the media browser owns its own
    /// `MediaService` call, not the timeline's.
    @State private var openingMedia: Set<URL> = []

    private struct Preview: Identifiable {
        let id = UUID()
        let image: Image
        let pixelSize: CGSize
    }

    var body: some View {
        VStack(spacing: 0) {
            doneRow.frame(height: Self.doneRowHeight)
            Group {
                if let viewModel {
                    MediaBrowserView(
                        media: viewModel.mediaItems.map {
                            .init(id: $0.id, url: $0.url,
                                  expired: $0.expired || ($0.url.map { viewModel.isUnavailable($0) || chatViewModel.isMediaUnavailable($0) } ?? false),
                                  isLoading: $0.url.map(openingMedia.contains) ?? false)
                        },
                        files: viewModel.fileItems.map {
                            .init(id: $0.id, url: $0.url, name: $0.name,
                                  sizeBytes: $0.sizeBytes,
                                  expired: $0.expired || ($0.url.map(chatViewModel.isMediaUnavailable) ?? false),
                                  isLoading: $0.url.map(chatViewModel.isDownloadingFile) ?? false)
                        },
                        links: viewModel.links.map {
                            .init(id: $0.id, url: $0.url, context: $0.context, date: $0.timestamp)
                        },
                        loadFailed: viewModel.loadFailed,
                        thumbnail: { await viewModel.thumbnail(for: $0) },
                        onMediaTap: { cell in openImage(cell) },
                        onFileTap: { row in openFile(row) },
                        onLinkTap: { NSWorkspace.shared.open($0.url) }
                    )
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 520)   // rigid — Mac sheets ignore ideal sizes
        .task {
            guard viewModel == nil, let deps, let session else { return }
            let vm = MediaBrowserViewModel(
                store: deps.journalStore(for: session),
                convoID: chatViewModel.roomID,
                serverURL: session.homeserverURL,
                media: deps.mediaService(for: session))
            await vm.load()
            viewModel = vm
        }
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(
                image: preview.image,
                nativePixelSize: preview.pixelSize,
                onDismiss: { imagePreview = nil }
            )
        }
    }

    /// Sheet content is plain (not a `NavigationStack`), so a `.toolbar`
    /// item never renders on macOS — Mac sheets are window-modal, so that
    /// left the browser with no close affordance at all. In-content row
    /// mirrors `AttachmentFullscreenViewer.doneRow` / `MacAddAgentSheet`;
    /// `.cancelAction` also wires Esc.
    @ViewBuilder
    private var doneRow: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding()
        }
    }

    private static let doneRowHeight: CGFloat = 52

    private func openImage(_ cell: MediaBrowserView.MediaCell) {
        guard let url = cell.url, let deps, let session,
              !openingMedia.contains(url) else { return }
        let media = deps.mediaService(for: session)
        openingMedia.insert(url)
        Task {
            defer { openingMedia.remove(url) }
            if let sized = await media.sizedImage(for: url) {
                imagePreview = Preview(image: sized.image, pixelSize: sized.pixelSize)
            }
        }
    }

    private func openFile(_ row: MediaBrowserView.FileRow) {
        guard let url = row.url, !row.expired else { return }
        Task {
            if let tmp = await chatViewModel.writeTempFile(mxcURL: url, filename: row.name) {
                NSWorkspace.shared.open(tmp)
            }
        }
    }
}

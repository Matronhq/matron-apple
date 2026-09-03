import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronViewModels

/// iOS presentation of the per-chat media & links browser. Mirrors
/// MacMediaBrowserSheet: VM owned here, taps route to the pinch-zoom
/// viewer / file preview (QuickLook or share fallback) / openURL.
struct MediaBrowserSheet: View {
    let chatViewModel: ChatViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(\.openURL) private var openURL
    @State private var viewModel: MediaBrowserViewModel?
    @State private var preview: Preview?
    /// Media URLs whose full-size fetch is currently in flight — guards
    /// `openImage` against re-entrant taps stacking overlapping downloads,
    /// and drives `MediaCell.isLoading`'s spinner. Kept local to the sheet
    /// (not `ChatViewModel`) because the media browser owns its own
    /// `MediaService` call, not the timeline's. Mapping logic mirrors
    /// `MacMediaBrowserSheet` token-for-token.
    @State private var openingMedia: Set<URL> = []

    private enum Preview: Identifiable {
        case image(UUID, ImageGallery)
        case file(UUID, URL, filename: String)
        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    var body: some View {
        NavigationStack {
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
                        onLinkTap: { openURL($0.url) }
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Media")
            .navigationBarTitleDisplayMode(.inline)
        }
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
        .sheet(item: $preview) { presented in
            switch presented {
            case .image(_, let gallery):
                AttachmentFullscreenViewer(gallery: gallery, onDismiss: { preview = nil })
            case .file(_, let url, let filename):
                // Same routing as the timeline (#143): QuickLook when it
                // can preview the file, share-only fallback otherwise.
                FilePreviewSheet(url: url, filename: filename,
                                 onDone: { preview = nil })
            }
        }
    }

    private func openImage(_ cell: MediaBrowserView.MediaCell) {
        guard let url = cell.url, let deps, let session,
              !openingMedia.contains(url) else { return }
        let media = deps.mediaService(for: session)
        openingMedia.insert(url)
        Task {
            defer { openingMedia.remove(url) }
            if let sized = await media.sizedImage(for: url), let viewModel {
                preview = .image(UUID(), ImageGalleries.mediaGrid(
                    items: viewModel.mediaItems, tappedID: cell.id,
                    initial: ViewerImage(image: sized.image, pixelSize: sized.pixelSize),
                    media: media
                ))
            }
        }
    }

    private func openFile(_ row: MediaBrowserView.FileRow) {
        guard let url = row.url, !row.expired else { return }
        Task {
            if let tmp = await chatViewModel.writeTempFile(mxcURL: url, filename: row.name) {
                preview = .file(UUID(), tmp, filename: row.name)
            }
        }
    }
}

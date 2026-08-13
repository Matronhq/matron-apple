import SwiftUI
import MatronChat
import MatronDesignSystem
import MatronViewModels

/// iOS presentation of the per-chat media & links browser. Mirrors
/// MacMediaBrowserSheet: VM owned here, taps route to the pinch-zoom
/// viewer / share sheet / openURL.
struct MediaBrowserSheet: View {
    let chatViewModel: ChatViewModel
    @Environment(\.appDependencies) private var deps
    @Environment(\.currentSession) private var session
    @Environment(\.openURL) private var openURL
    @State private var viewModel: MediaBrowserViewModel?
    @State private var preview: Preview?

    private enum Preview: Identifiable {
        case image(UUID, Image)
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
                                  expired: $0.expired || ($0.url.map(viewModel.isUnavailable) ?? false))
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
            case .image(_, let img):
                AttachmentFullscreenViewer(image: img, onDismiss: { preview = nil })
            case .file(_, let url, let filename):
                // Mirrors ChatView.fileShareSheet(url:filename:) (private there).
                VStack(spacing: 16) {
                    Image(systemName: "doc")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .padding(.top, 32)
                    Text(filename)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                    Button("Done") { preview = nil }
                        .padding(.top, 4)
                    Spacer()
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
    }

    private func openImage(_ cell: MediaBrowserView.MediaCell) {
        guard let url = cell.url, let deps, let session else { return }
        let media = deps.mediaService(for: session)
        Task {
            if let img = await media.swiftUIImage(for: url) {
                preview = .image(UUID(), img)
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

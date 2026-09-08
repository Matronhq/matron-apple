import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import MatronChat
import MatronJournal
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// iOS host for a single tracker item: owns an `ItemDetailViewModel` and
/// wires the leaf `ItemDetailView` to the app's media service, the
/// composer's attach flow, `VoiceRecorder`, and the shared attachment
/// viewers. Pushed from `ItemsDrawer`'s `NavigationStack`.
struct ItemDetailHost: View {
    let itemID: String
    let session: UserSession
    let onOpenConversation: (String) -> Void

    @Environment(\.appDependencies) private var deps
    @Environment(\.openURL) private var openURL
    @State private var viewModel: ItemDetailViewModel?
    /// Resolved image attachments, keyed by `blobRef` — `ItemDetailView`'s
    /// `image` closure is a synchronous lookup, so this is populated ahead
    /// of render by a `.task(id:)` below rather than fetched on demand.
    @State private var imageCache: [String: Image] = [:]
    @State private var originTitle: String?
    @State private var attachmentPreview: AttachmentPreview?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotosPicker = false
    @State private var showFileImporter = false
    /// `ItemCommentComposer` (DesignSystem) only forwards intents — this
    /// host owns the recorder, mirroring `ComposerView`'s own split.
    @State private var recorder = VoiceRecorder()

    private enum AttachmentPreview: Identifiable {
        case image(id: UUID = UUID(), ImageGallery)
        case file(id: UUID = UUID(), URL, filename: String)
        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    var body: some View {
        Group {
            if let vm = viewModel, let item = vm.item {
                ItemDetailView(
                    model: .init(
                        item: item,
                        comments: vm.comments,
                        pending: vm.pendingComments.map(Self.pending),
                        originTitle: originTitle,
                        availableResolutions: vm.availableResolutions,
                        isBusy: vm.isBusy
                    ),
                    draft: Binding(get: { vm.draft }, set: { vm.draft = $0 }),
                    image: { imageCache[$0.blobRef] },
                    onOpenAttachment: { open($0) },
                    onOpenLink: { openURL($0) },
                    onOpenConversation: onOpenConversation,
                    onSubmit: { Task { await vm.submitComment(attachments: []) } },
                    onAttach: { showPhotosPicker = true },
                    onVoiceNote: { Task { await startRecording(vm) } },
                    onClose: { resolution in Task { await vm.close(resolution: resolution, comment: nil) } },
                    onReopen: { Task { await vm.reopen() } }
                )
                .overlay(alignment: .bottom) {
                    if case let .recording(start) = recorder.state {
                        recordingBar(start: start, vm: vm)
                    }
                }
                .task(id: item.attachments) { await loadImages(item.attachments) }
                .task(id: item.originConvoID) { await loadOriginTitle(item.originConvoID) }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Tracker", isPresented: Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })) {
            Button("OK") { viewModel?.error = nil }
        } message: {
            Text(viewModel?.error ?? "")
        }
        .task {
            guard let deps else { return }
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            viewModel = vm
            vm.start()
        }
        .onDisappear {
            viewModel?.stop()
            recorder.cancel()
        }
        .onChange(of: photoItem) { _, newItem in
            guard let newItem, let vm = viewModel else { return }
            Task { await attachPickedPhoto(newItem, vm: vm) }
        }
        .photosPicker(
            isPresented: $showPhotosPicker,
            selection: $photoItem,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard let vm = viewModel else { return }
            switch result {
            case .success(let urls):
                Task { await attachPickedFiles(urls, vm: vm) }
            case .failure(let error):
                vm.error = error.localizedDescription
            }
        }
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let gallery):
                AttachmentFullscreenViewer(gallery: gallery, onDismiss: { attachmentPreview = nil })
            case .file(_, let url, let filename):
                FilePreviewSheet(url: url, filename: filename, onDone: { attachmentPreview = nil })
            }
        }
    }

    private static func pending(_ r: ItemOutboxRecord) -> ItemDetailView.PendingComment {
        struct Payload: Decodable { var body: String; var attachments: [TrackerAttachment] }
        let decoded = r.payloadJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
        return .init(id: r.localID, body: decoded?.body ?? "", attachmentCount: decoded?.attachments.count ?? 0,
                     attempts: r.attempts, lastError: r.lastError)
    }

    private func mediaURL(for blobRef: String) -> URL {
        session.homeserverURL.appendingPathComponent("media").appendingPathComponent(blobRef)
    }

    private func loadImages(_ attachments: [TrackerAttachment]) async {
        guard let deps else { return }
        let media = deps.mediaService(for: session)
        for a in attachments where a.isImage && imageCache[a.blobRef] == nil {
            if let img = await media.swiftUIImage(for: mediaURL(for: a.blobRef)) {
                imageCache[a.blobRef] = img
            }
        }
    }

    /// `conversation(id:)` — same cheap per-id store read `ItemsDrawer`
    /// uses for the list's `originTitles`, no dedicated "title for id" API
    /// exists (grep confirmed).
    private func loadOriginTitle(_ convoID: String) async {
        guard let deps else { originTitle = nil; return }
        originTitle = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
    }

    private func open(_ attachment: TrackerAttachment) {
        guard let deps else { return }
        let url = mediaURL(for: attachment.blobRef)
        let media = deps.mediaService(for: session)
        if attachment.isImage {
            Task {
                guard let sized = await media.sizedImage(for: url) else { return }
                imageCache[attachment.blobRef] = sized.image
                attachmentPreview = .image(ImageGallery.single(sized.image, pixelSize: sized.pixelSize))
            }
        } else {
            Task {
                guard let data = await media.fetchBytes(mxcURL: url) else { return }
                let name = attachment.name.isEmpty ? attachment.blobRef : attachment.name
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: tmp)
                attachmentPreview = .file(tmp, filename: name)
            }
        }
    }

    /// Mirrors `ComposerView.stagePhotoData` — resolve the picker's
    /// transferable data, pick a real extension from
    /// `supportedContentTypes` (never trust the abstract PHAsset
    /// identifier), and submit it as its own comment.
    private func attachPickedPhoto(_ item: PhotosPickerItem, vm: ItemDetailViewModel) async {
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                vm.error = "Couldn't load that item. If it's stored in iCloud, try downloading it first."
                return
            }
            let ext = ComposerView.pickedExtension(for: item.supportedContentTypes)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            await vm.submitComment(attachments: [(data, "photo-\(UUID().uuidString).\(ext)", mime)])
        } catch {
            vm.error = error.localizedDescription
        }
    }

    private func attachPickedFiles(_ urls: [URL], vm: ItemDetailViewModel) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                await vm.submitComment(attachments: [(data, url.lastPathComponent, mime)])
            } catch {
                vm.error = error.localizedDescription
            }
        }
    }

    private func startRecording(_ vm: ItemDetailViewModel) async {
        do {
            try await recorder.start()
        } catch {
            vm.error = error.localizedDescription
        }
    }

    /// Minimal press-to-record UI — `ComposerView`'s own recording bar is
    /// entangled with its composer state (draft text, staged-attachment
    /// tray) closely enough that reusing it directly would drag that
    /// coupling into the tracker; this is a standalone bar over the same
    /// `VoiceRecorder` seam instead.
    private func recordingBar(start: Date, vm: ItemDetailViewModel) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(start, style: .timer).monospacedDigit().foregroundStyle(.primary)
            Spacer()
            Button("Cancel") { recorder.cancel() }.foregroundStyle(.secondary)
            Button {
                guard let result = recorder.stop() else { return }
                Task { await vm.sendVoiceNote(url: result.url) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
        }
        .padding()
        .background(.bar)
    }
}

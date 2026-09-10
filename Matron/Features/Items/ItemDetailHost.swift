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
    /// The chat this drawer was opened from (`ItemsPanelViewModel.convoID`)
    /// — used to hide the "opened from…" origin link when it would just
    /// point back at the chat already underneath the drawer. Optional
    /// since the app shell's Decisions instance has no home conversation
    /// (spec §1): with `nil` every origin link is shown.
    let currentConvoID: String?
    let onOpenConversation: (String) -> Void
    /// Opens ANOTHER tracker item — a `[#12](matron://item/12)` link inside
    /// this item's body or one of its comments (item #115) — in the same
    /// container this host lives in, so "back" still means what it meant.
    /// `nil` leaves item links inert (never handed to the OS either way).
    var onOpenItem: ((String) -> Void)? = nil
    /// This surface's item LIST, for a number this device has never synced.
    /// `nil` where the surface has none to fall back to — an item pushed
    /// over a chat has the chat below it, not a list.
    var onOpenItemsList: (() -> Void)? = nil

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
    /// Paperclip → chooser between the two attach flows, mirroring
    /// `AttachmentPicker`'s Menu — presenting `PhotosPicker` directly from
    /// a `Menu` row never shows it (menu dismissal takes the presentation
    /// context with it, ComposerView's own comment on the same gotcha), so
    /// this only sets a flag; the picker itself is a sibling modifier.
    @State private var showAttachChooser = false
    /// `ItemCommentComposer` (DesignSystem) only forwards intents — this
    /// host owns the recorder, mirroring `ComposerView`'s own split.
    @State private var recorder = VoiceRecorder()
    /// blobRefs with an in-flight `open(_:)` fetch — a second tap on the
    /// same attachment while its bytes are still downloading is a no-op
    /// instead of a redundant fetch, and drives the `fetchingBar` overlay
    /// (fix wave part 2, C2/I9).
    @State private var fetchingBlobRefs: Set<String> = []
    /// `ItemReadMemory.wasAtBottom(itemID:)`, read once in the `.task`
    /// below (not on every render) and handed to `ItemDetailView` as
    /// `startsAtBottom`. A fresh push of this destination per item id
    /// (see `ItemsDrawer`'s `navigationDestination`) gives this `@State`
    /// a fresh identity per item, unlike the Mac host, which swaps items
    /// in place and hoists the equivalent state onto `MacItemsPaneState`.
    @State private var startsAtBottom = false
    /// Latest bottom-visibility the comment thread reported
    /// (`ItemDetailView.onBottomVisibilityChange`), persisted to
    /// `ItemReadMemory` in `.onDisappear`.
    @State private var isAtBottom = false
    /// `[#12](matron://item/12)` taps inside the body or a comment. Stable
    /// closure identity for the environment; navigation happens in the
    /// `onChange` below (see `TrackerItemLinkRelay`).
    @State private var itemLinkRelay = TrackerItemLinkRelay()

    /// A tapped `matron://item/<n>` link in this item's body or a comment.
    /// Same rule as the chat timeline: known number → that item, in this
    /// same container; unknown → this surface's list, where it has one.
    private func openTrackerItem(num: Int) {
        guard let deps else { return }
        guard let item = try? deps.journalStore(for: session).item(num: num) else {
            onOpenItemsList?()
            return
        }
        // A link to the item already on screen is a no-op rather than a
        // second identical push.
        guard item.id != itemID else { return }
        onOpenItem?(item.id)
    }

    /// A tapped link chip (`item.links`). Routed through the same policy as
    /// message bodies so an item link works here too — and so no `matron://`
    /// URL is ever handed to the OS, which has no handler for the scheme.
    private func openLink(_ url: URL) {
        switch MatronItemLink.action(for: url) {
        case .openTrackerItem(let number): openTrackerItem(num: number)
        case .swallow: break
        case .system(let url): openURL(url)
        }
    }

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
                // Bugbot: the preload previously only walked `item.attachments`
                // — a comment's own image attachments never resolved, so
                // `image:` below returned `nil` for every reply photo. This
                // covers item + every comment, de-duplicated by `blobRef`,
                // and its `.task(id:)` re-runs whenever `vm.comments` gains a
                // new attachment-bearing reply.
                let images = Self.imageAttachments(item: item, comments: vm.comments)
                ItemDetailView(
                    model: .init(
                        item: item,
                        comments: vm.comments,
                        pending: vm.pendingComments.map(Self.pending),
                        // Bugbot: hide the "opened from…" link when it would
                        // just point back at the chat already underneath the
                        // drawer — tapping it would silently no-op the push
                        // (see ChatView's `onOpenConversation` dedup) with no
                        // visible feedback, so hiding it is the honest UI.
                        originTitle: item.originConvoID == currentConvoID ? nil : originTitle,
                        availableResolutions: vm.availableResolutions,
                        isBusy: vm.isBusy,
                        loadedCommentCount: vm.loadedCommentCount
                    ),
                    draft: Binding(get: { vm.draft }, set: { vm.draft = $0 }),
                    image: { imageCache[$0.blobRef] },
                    onOpenAttachment: { open($0) },
                    onOpenLink: { openLink($0) },
                    onOpenConversation: onOpenConversation,
                    onSubmit: { Task { await vm.submitComment(attachments: []) } },
                    onAttach: { showAttachChooser = true },
                    onVoiceNote: { Task { await startRecording(vm) } },
                    onClose: { resolution in Task { await vm.close(resolution: resolution, comment: nil) } },
                    onReopen: { Task { await vm.reopen() } },
                    startsAtBottom: startsAtBottom,
                    onBottomVisibilityChange: { isAtBottom = $0 }
                )
                // Resolve/reopen lives in the navigation bar's top-right
                // corner, out of the composer's way (see the control's
                // own doc comment).
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        ItemResolveControl(isOpen: item.state == .open, resolutions: vm.availableResolutions, isBusy: vm.isBusy,
                                           onClose: { resolution in Task { await vm.close(resolution: resolution, comment: nil) } },
                                           onReopen: { Task { await vm.reopen() } })
                    }
                }
                .overlay(alignment: .bottom) {
                    if case let .recording(start) = recorder.state {
                        recordingBar(start: start, vm: vm)
                    } else if !fetchingBlobRefs.isEmpty {
                        fetchingBar
                    }
                }
                .task(id: images) { await loadImages(images) }
                .task(id: item.originConvoID) { await loadOriginTitle(item.originConvoID) }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Mirrors `AttachmentPicker`'s chooser — the paperclip previously
        // jumped straight to `showPhotosPicker`, which left the file-import
        // flow unreachable from the comment composer entirely (Bugbot).
        // Item links inside the body / comments (item #115).
        .environment(\.openTrackerItem, itemLinkRelay.action)
        .onChange(of: itemLinkRelay.pending) { _, tap in
            guard let tap else { return }
            openTrackerItem(num: tap.num)
        }
        .confirmationDialog("Attach", isPresented: $showAttachChooser) {
            Button("Photo Library") { showPhotosPicker = true }
            Button("Choose File…") { showFileImporter = true }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Tracker", isPresented: Binding(get: { viewModel?.error != nil }, set: { if !$0 { viewModel?.error = nil } })) {
            Button("OK") { viewModel?.error = nil }
        } message: {
            Text(viewModel?.error ?? "")
        }
        .task {
            startsAtBottom = ItemReadMemory().wasAtBottom(itemID: itemID)
            // Seed from memory (Bugbot, PR #198): a pop before the thread
            // reports visibility must not overwrite a read-to-end as unread.
            isAtBottom = startsAtBottom
            guard let deps else { return }
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            viewModel = vm
            vm.start()
        }
        .onDisappear {
            ItemReadMemory().store(itemID: itemID, atBottom: isAtBottom)
            viewModel?.stop()
            recorder.cancel()
        }
        // iPad drag-and-drop from Files/Photos, mirroring the Mac detail
        // pane's `.onDrop` (Task: tracker composer parity). `attachPickedFiles`
        // already owns security-scoped reading + `submitAttachments`.
        .dropDestination(for: URL.self) { urls, _ in
            guard let vm = viewModel, !urls.isEmpty else { return false }
            Task { await attachPickedFiles(urls, vm: vm) }
            return true
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
        // App shell (spec §3): the tab bar shows only at a tab's root.
        .toolbar(.hidden, for: .tabBar)
    }

    /// Every image attachment worth preloading: the item's own, plus every
    /// comment's (including pending/queued ones stay out — those resolve
    /// through the local temp files the composer already staged, not the
    /// server media path). De-duplicated by `blobRef` since the same image
    /// could in principle appear twice.
    private static func imageAttachments(item: TrackerItem, comments: [TrackerComment]) -> [TrackerAttachment] {
        var seen = Set<String>()
        var result: [TrackerAttachment] = []
        for a in item.attachments where a.isImage && seen.insert(a.blobRef).inserted { result.append(a) }
        for c in comments {
            for a in c.attachments where a.isImage && seen.insert(a.blobRef).inserted { result.append(a) }
        }
        return result
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

    /// `conversationOriginLabel(id:)` — same cheap per-id store read
    /// `ItemsDrawer` uses for the list's `originTitles`, naming the box
    /// alongside the title (item #114).
    private func loadOriginTitle(_ convoID: String) async {
        guard let deps else { originTitle = nil; return }
        originTitle = try? deps.journalStore(for: session).conversationOriginLabel(id: convoID)
    }

    private func open(_ attachment: TrackerAttachment) {
        guard let deps else { return }
        let blobRef = attachment.blobRef
        // A second tap while the first fetch is still in flight is a
        // no-op, not a redundant download (fix wave part 2, C2/I9).
        guard !fetchingBlobRefs.contains(blobRef) else { return }
        let url = mediaURL(for: blobRef)
        let media = deps.mediaService(for: session)
        if attachment.isImage {
            fetchingBlobRefs.insert(blobRef)
            Task {
                defer { fetchingBlobRefs.remove(blobRef) }
                guard let sized = await media.sizedImage(for: url) else { return }
                imageCache[blobRef] = sized.image
                attachmentPreview = .image(ImageGallery.single(sized.image, pixelSize: sized.pixelSize))
            }
        } else {
            let name = attachment.name.isEmpty ? attachment.blobRef : attachment.name
            // Reuse a temp file already written for this blobRef instead of
            // spending a network round trip re-fetching bytes we already
            // have on disk (fix wave part 2, C2/I9) — checked BEFORE
            // starting the fetch, so a cache hit never touches the network.
            if let cached = AttachmentTempFiles.existingFile(name: name, blobRef: blobRef) {
                attachmentPreview = .file(cached, filename: name)
                return
            }
            fetchingBlobRefs.insert(blobRef)
            Task {
                defer { fetchingBlobRefs.remove(blobRef) }
                guard let data = await media.fetchBytes(mxcURL: url) else { return }
                // `AttachmentTempFiles.write` (fix wave, item H) — the
                // shared path-traversal-safe, collision-safe temp-file
                // writer `ChatViewModel` itself now delegates to, instead
                // of a hand-rolled `appendingPathComponent(name)` that
                // trusted a server-supplied filename raw. do/catch: a
                // write failure surfaces via `vm.error` and never presents
                // a preview over a file that doesn't exist.
                do {
                    let dest = try AttachmentTempFiles.write(data, name: name, blobRef: blobRef)
                    attachmentPreview = .file(dest, filename: name)
                } catch {
                    viewModel?.error = error.localizedDescription
                }
            }
        }
    }

    /// Mirrors `ComposerView.stagePhotoData` — resolve the picker's
    /// transferable data, pick a real extension from
    /// `supportedContentTypes` (never trust the abstract PHAsset
    /// identifier), and submit it as its own attachment-only comment.
    /// `submitAttachments` (fix wave, item B) — not `submitComment` —
    /// because the latter posts whatever's currently sitting in `draft`
    /// as the attachment's comment body and clears it, silently eating
    /// whatever the person was still typing.
    private func attachPickedPhoto(_ item: PhotosPickerItem, vm: ItemDetailViewModel) async {
        defer { photoItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                vm.error = "Couldn't load that item. If it's stored in iCloud, try downloading it first."
                return
            }
            let ext = ComposerView.pickedExtension(for: item.supportedContentTypes)
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            _ = await vm.submitAttachments([(data, "photo-\(UUID().uuidString).\(ext)", mime)])
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
                _ = await vm.submitAttachments([(data, url.lastPathComponent, mime)])
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

    /// Small fetch-in-progress banner for a file-attachment tap (fix wave
    /// part 2, C2/I9). `AttachmentFile`/`AttachmentImage` are DesignSystem
    /// leaf views with no per-row loading state to wire up — this is a
    /// standalone overlay, same slot as `recordingBar`, rather than a
    /// disabled/spinner state on the tapped row itself.
    private var fetchingBar: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Opening attachment…").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar, in: Capsule())
        .padding(.bottom, 8)
    }
}

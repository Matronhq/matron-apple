import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatronModels
import MatronJournal
import MatronViewModels
import MatronDesignSystem

/// Header chrome shared by the list and detail pushes: title, back/close.
/// Split out of `MacItemsPane` so it — and the populated list inside it —
/// can be snapshot-tested with static data, no view model, exactly as
/// `MacSummariesPanel` is tested without a VM (see
/// `MacItemsPaneSnapshotTests`).
struct MacItemsPaneChrome<Content: View>: View {
    let title: String
    var showsBackChevron = false
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if showsBackChevron {
                    Button(action: onClose) { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain)
                        .help("Back to the chat")
                        .accessibilityLabel("Back to the chat")
                }
                Text(title).font(.headline)
                Spacer()
                if !showsBackChevron {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Close")
                        .accessibilityLabel("Close")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content()
        }
        .background(.background)
    }
}

/// Mac tasks-and-decisions pane (spec 2026-09-08-items-tracker-apps, Task
/// 10). Shares the sub-chat slot in `MacChatView`: opening it closes an
/// open sub-chat and vice versa, and both take either the side-by-side
/// `HSplitView` shape (wide window) or a narrow takeover with a back
/// chevron, mirroring `MacSubChatPane`'s own two layouts.
struct MacItemsPane: View {
    let viewModel: ItemsPanelViewModel
    let session: UserSession
    var showsBackChevron = false
    let onOpenConversation: (String) -> Void
    let onClose: () -> Void
    @Environment(\.appDependencies) private var deps
    /// Pushed item ids — `String` (not `TrackerItem`, which isn't
    /// `Hashable` the way `NavigationPath` values need to stay cheap to
    /// diff) so `navigationDestination(for: String.self)` resolves the
    /// live item from the store rather than carrying a snapshot that could
    /// go stale while pushed.
    @State private var path: [String] = []
    @State private var showCreate = false
    @State private var originTitles: [String: String] = [:]

    var body: some View {
        MacItemsPaneChrome(title: "Tasks & decisions", showsBackChevron: showsBackChevron, onClose: onClose) {
            NavigationStack(path: $path) {
                ItemsListView(
                    model: .init(
                        needsYou: viewModel.sections.needsYou, tasks: viewModel.sections.tasks,
                        decisions: viewModel.sections.decisions, done: viewModel.sections.done,
                        originTitles: originTitles, isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
                    scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                    convoID: viewModel.convoID,
                    thumbnail: { _ in nil },
                    onSelect: { path.append($0.id) },
                    onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                    onCreate: { showCreate = true },
                    onOpenConversation: handleOpenConversation)
                .navigationDestination(for: String.self) { id in
                    MacItemDetailHost(itemID: id, session: session, currentConvoID: viewModel.convoID,
                                       onOpenConversation: handleOpenConversation)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } }
        }
        .task(id: viewModel.scope) {
            // Titles for the "All" scope rows come from the local store's
            // conversation list — one cheap read per scope switch (ruling
            // 2: no per-conversation round trip, `ItemsListView` already
            // falls back to "Another chat" for a miss).
            guard let deps else { return }
            originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
        }
        .alert("Tracker", isPresented: Binding(get: { viewModel.error != nil }, set: { if !$0 { viewModel.error = nil } })) {
            Button("OK") { viewModel.error = nil }
        } message: {
            Text(viewModel.error ?? "")
        }
    }

    /// Bugbot: an "open conversation" tap that targets the chat already
    /// underneath this pane would just re-select the current room — no
    /// visible effect other than a confusing no-op. Closing the pane
    /// instead surfaces that chat immediately, which is what the tap
    /// actually meant.
    private func handleOpenConversation(_ id: String) {
        if id == viewModel.convoID {
            onClose()
        } else {
            onOpenConversation(id)
        }
    }
}

/// Minimal create sheet (ruling 4): kind picker, title, Markdown body,
/// Create button. `onCreate` hands straight to
/// `ItemsPanelViewModel.create(kind:title:body:)`, which owns validation
/// and the outbox enqueue.
struct NewItemSheet: View {
    let onCreate: (ItemKind, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ItemKind = .task
    @State private var title = ""
    /// Not named `body` — that collides with `View.body`.
    @State private var itemBody = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New item").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(ItemKind.allCases, id: \.self) { Text(ItemGlyph.label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Title", text: $title)
            TextField("Details (Markdown)", text: $itemBody, axis: .vertical)
                .lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { onCreate(kind, title, itemBody); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

/// Item detail push destination. Owns its own `ItemDetailViewModel`
/// (`deps.makeItemDetailViewModel`, started in `.task`, stopped in
/// `onDisappear` — same lifecycle shape as every other Mac detail host),
/// a small image cache for the attachments `ItemDetailView` asks it to
/// render synchronously (ruling 3: `MediaService` has no sync peek, so a
/// `.task(id:)` keyed on the current attachment set fills `images` as
/// bytes arrive), and a minimal voice-note recorder (ruling 3: the full
/// composer/hotkey recorder UI is too entangled with `MacComposerView`'s
/// own state to reuse directly — this wires the same `VoiceRecorder`
/// engine to a small inline recording bar instead).
struct MacItemDetailHost: View {
    let itemID: String
    let session: UserSession
    /// The chat this pane was opened from (`ItemsPanelViewModel.convoID`)
    /// — used to hide the "opened from…" origin link when it would just
    /// point back at the chat already underneath the pane (Bugbot; mirrors
    /// iOS `ItemDetailHost.currentConvoID`).
    let currentConvoID: String
    let onOpenConversation: (String) -> Void
    @Environment(\.appDependencies) private var deps
    @State private var viewModel: ItemDetailViewModel?
    @State private var images: [String: Image] = [:]
    @State private var galleryPreview: GalleryPreview?
    @State private var recorder = VoiceRecorder()
    /// Cached origin-conversation title, loaded once per item via
    /// `.task(id:)` below — mirrors iOS `ItemDetailHost.originTitle`.
    /// Previously this was a synchronous full-table `conversationTitles()`
    /// read on every body re-evaluation; a per-id `conversation(id:)` read,
    /// cached, is the fix.
    @State private var originTitle: String?

    /// Identifiable wrapper so `.sheet(item:)` has something to key on —
    /// `ImageGallery` itself isn't `Identifiable` (same pattern as
    /// `MacChatView.ImagePreview`).
    struct GalleryPreview: Identifiable {
        let id = UUID()
        let gallery: ImageGallery
    }

    private var item: TrackerItem? { viewModel?.item }
    private var imageAttachments: [TrackerAttachment] {
        guard let item else { return [] }
        return (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let viewModel, let item {
                    ItemDetailView(
                        model: .init(
                            item: item, comments: viewModel.comments,
                            pending: viewModel.pendingComments.map {
                                .init(id: $0.localID, body: pendingBody($0), attachmentCount: pendingAttachments($0),
                                      attempts: $0.attempts, lastError: $0.lastError)
                            },
                            // Bugbot: hide the "opened from…" link when it
                            // would just point back at the chat already
                            // underneath the pane — tapping it would silently
                            // no-op (see `handleOpenConversation`), so hiding
                            // it is the honest UI.
                            originTitle: item.originConvoID == currentConvoID ? nil : originTitle,
                            availableResolutions: viewModel.availableResolutions, isBusy: viewModel.isBusy),
                        draft: Binding(get: { viewModel.draft }, set: { viewModel.draft = $0 }),
                        image: { images[$0.blobRef] },
                        onOpenAttachment: { openAttachment($0, in: item) },
                        onOpenLink: { NSWorkspace.shared.open($0) },
                        onOpenConversation: onOpenConversation,
                        onSubmit: { Task { await viewModel.submitComment(attachments: []) } },
                        onAttach: { pickFiles { files in Task { await viewModel.submitComment(attachments: files) } } },
                        onVoiceNote: { startVoiceNote() },
                        onClose: { r in Task { await viewModel.close(resolution: r, comment: nil) } },
                        onReopen: { Task { await viewModel.reopen() } })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if case let .recording(start) = recorder.state {
                voiceRecordingBar(start: start)
            }
        }
        .navigationTitle("")
        .task {
            guard viewModel == nil, let deps else { return }
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            viewModel = vm
            vm.start()
        }
        .task(id: imageAttachments.map(\.blobRef)) {
            guard let deps else { return }
            let media = deps.mediaService(for: session)
            for attachment in imageAttachments where images[attachment.blobRef] == nil {
                guard let image = await media.swiftUIImage(for: mediaURL(attachment)) else { continue }
                images[attachment.blobRef] = image
            }
        }
        .task(id: item?.originConvoID) {
            guard let convoID = item?.originConvoID, let deps else { originTitle = nil; return }
            originTitle = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
        }
        .onDisappear {
            viewModel?.stop()
            recorder.cancel()
        }
        .sheet(item: $galleryPreview) { preview in
            AttachmentFullscreenViewer(gallery: preview.gallery, onDismiss: { galleryPreview = nil })
        }
    }

    private func mediaURL(_ a: TrackerAttachment) -> URL {
        session.homeserverURL.appendingPathComponent("media").appendingPathComponent(a.blobRef)
    }

    private func pendingBody(_ r: ItemOutboxRecord) -> String {
        (try? JSONSerialization.jsonObject(with: Data(r.payloadJSON.utf8)) as? [String: Any])?["body"] as? String ?? ""
    }

    private func pendingAttachments(_ r: ItemOutboxRecord) -> Int {
        ((try? JSONSerialization.jsonObject(with: Data(r.payloadJSON.utf8)) as? [String: Any])?["attachments"] as? [Any])?.count ?? 0
    }

    /// Image attachments open the gallery viewer (item + every comment's
    /// image attachments, in thread order); everything else downloads to a
    /// temp file and hands it to the user's default app, mirroring the
    /// chat timeline's file-tap path (`ChatViewModel.writeTempFile` →
    /// `NSWorkspace.open`).
    private func openAttachment(_ a: TrackerAttachment, in item: TrackerItem) {
        guard let deps else { return }
        if a.isImage {
            let all = (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
            let urls = all.map(mediaURL)
            galleryPreview = GalleryPreview(gallery: ImageGalleries.urls(urls, tapped: mediaURL(a), deps: deps, session: session))
        } else {
            Task {
                guard let data = await deps.mediaService(for: session).fetchBytes(mxcURL: mediaURL(a)) else { return }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent(a.name.isEmpty ? a.blobRef : a.name)
                try? data.write(to: url)
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func pickFiles(_ done: @escaping ([(data: Data, name: String, mime: String)]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            done(panel.urls.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                return (data, url.lastPathComponent, mime)
            })
        }
    }

    /// Starts recording; `voiceRecordingBar` below stops it and hands the
    /// file to `viewModel.sendVoiceNote(url:)`. `ItemCommentComposer` (the
    /// DesignSystem leaf view) has no recording state of its own — its mic
    /// button just fires this closure once — so the "recording…" affordance
    /// lives here, as a bar under the whole detail view rather than
    /// replacing the composer in place (the composer is private to
    /// `ItemDetailView`'s layout).
    private func startVoiceNote() {
        Task {
            do { try await recorder.start() }
            catch { viewModel?.error = error.localizedDescription }
        }
    }

    private func voiceRecordingBar(start: Date) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(start, style: .timer).monospacedDigit()
            Spacer()
            Button("Cancel") { recorder.cancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button {
                guard let result = recorder.stop() else { return }
                Task { await viewModel?.sendVoiceNote(url: result.url) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.bar)
    }
}

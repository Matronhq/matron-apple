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

/// Pane-scoped state hoisted out of `MacItemsPane`/`MacItemDetailHost` (I6,
/// Mac fix wave part 1). `MacChatView`'s wide (`HSplitView`) and narrow
/// (takeover) branches used to each construct their OWN `MacItemsPane(...)`
/// — two separate call sites, hence two separate SwiftUI identities — so
/// crossing `sideBySideMinWidth` mid-session tore the whole subtree down
/// and rebuilt it, dropping the navigation stack, the open item's draft
/// text, and an in-flight voice-note recording.
///
/// `MacChatView` now owns ONE instance of this class
/// (`@State private var itemsPaneState = MacItemsPaneState()`, stable for
/// the view's own lifetime, i.e. survives width-crossing rebuilds but
/// resets naturally on a genuine room switch, when `MacChatView` itself is
/// torn down) and hands it to `MacItemsPane` from both branches, so a
/// width-crossing rebuild finds all of this already populated instead of
/// starting from scratch. Detail-VM/recorder teardown lives in
/// `MacChatView`'s outer `onDisappear` (which does NOT refire on a
/// width-crossing branch move — see its own comment) rather than in
/// `MacItemDetailHost`, for the same reason: a host torn down and rebuilt
/// for the SAME pushed item must not stop the VM out from under its own
/// rebuild.
@MainActor @Observable
final class MacItemsPaneState {
    var path: [String] = []
    var showCreate = false
    var originTitles: [String: String] = [:]

    /// Detail state for whichever item is currently pushed
    /// (`path.last`). `detailItemID` is the guard `MacItemDetailHost`
    /// checks before (re)creating `detailViewModel` — matching ids means
    /// "this is a rebuild of the same push, keep what's here"; a
    /// mismatch means real navigation to a different item, which tears
    /// down the old VM and starts a fresh one.
    var detailItemID: String?
    var detailViewModel: ItemDetailViewModel?
    var detailImages: [String: Image] = [:]
    var detailGalleryPreview: MacItemDetailHost.GalleryPreview?
    var detailOriginTitle: String?
    /// One recorder shared across whichever item is open — mirrors the
    /// single-recorder-per-host design from before hoisting; a user
    /// switching items mid-recording is an edge case this doesn't newly
    /// introduce (the original per-host `@State` recorder had the same
    /// "belongs to whatever's current" property).
    let detailRecorder = VoiceRecorder()

    init() {}
}

/// Mac tasks-and-decisions pane (spec 2026-09-08-items-tracker-apps, Task
/// 10). Shares the sub-chat slot in `MacChatView`: opening it closes an
/// open sub-chat and vice versa, and both take either the side-by-side
/// `HSplitView` shape (wide window) or a narrow takeover with a back
/// chevron, mirroring `MacSubChatPane`'s own two layouts.
struct MacItemsPane: View {
    let viewModel: ItemsPanelViewModel
    let session: UserSession
    /// Owned by `MacChatView`, shared by both layout branches — see
    /// `MacItemsPaneState`'s doc comment.
    let state: MacItemsPaneState
    var showsBackChevron = false
    let onOpenConversation: (String) -> Void
    let onClose: () -> Void
    @Environment(\.appDependencies) private var deps

    var body: some View {
        MacItemsPaneChrome(title: "Tasks & decisions", showsBackChevron: showsBackChevron, onClose: onClose) {
            NavigationStack(path: Binding(get: { state.path }, set: { state.path = $0 })) {
                ItemsListView(
                    model: .init(
                        needsYou: viewModel.sections.needsYou, tasks: viewModel.sections.tasks,
                        decisions: viewModel.sections.decisions, done: viewModel.sections.done,
                        originTitles: state.originTitles, isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing),
                    scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                    convoID: viewModel.convoID,
                    thumbnail: { _ in nil },
                    onSelect: { state.path.append($0.id) },
                    onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                    onCreate: { state.showCreate = true },
                    onOpenConversation: handleOpenConversation)
                .navigationDestination(for: String.self) { id in
                    MacItemDetailHost(itemID: id, session: session, currentConvoID: viewModel.convoID,
                                       state: state, onOpenConversation: handleOpenConversation)
                }
            }
        }
        .sheet(isPresented: Binding(get: { state.showCreate }, set: { state.showCreate = $0 })) {
            NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } }
        }
        .task(id: viewModel.scope) {
            // Titles for the "All" scope rows come from the local store's
            // conversation list — one cheap read per scope switch (ruling
            // 2: no per-conversation round trip, `ItemsListView` already
            // falls back to "Another chat" for a miss).
            guard let deps else { return }
            state.originTitles = (try? deps.journalStore(for: session).conversationTitles()) ?? [:]
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

/// Item detail push destination. Reads/writes everything through the
/// shared `MacItemsPaneState` (I6) rather than owning its own `@State` —
/// see that type's doc comment for why. `deps.makeItemDetailViewModel` is
/// called only when `state.detailItemID != itemID` (a genuine navigation
/// to a different item; a rebuild for the SAME item is a no-op here and
/// finds everything already populated). Image loading and the voice-note
/// recorder follow the same "read/write through `state`" shape.
struct MacItemDetailHost: View {
    let itemID: String
    let session: UserSession
    /// The chat this pane was opened from (`ItemsPanelViewModel.convoID`)
    /// — used to hide the "opened from…" origin link when it would just
    /// point back at the chat already underneath the pane (Bugbot; mirrors
    /// iOS `ItemDetailHost.currentConvoID`).
    let currentConvoID: String
    let state: MacItemsPaneState
    let onOpenConversation: (String) -> Void
    @Environment(\.appDependencies) private var deps

    /// Identifiable wrapper so `.sheet(item:)` has something to key on —
    /// `ImageGallery` itself isn't `Identifiable` (same pattern as
    /// `MacChatView.ImagePreview`).
    struct GalleryPreview: Identifiable {
        let id = UUID()
        let gallery: ImageGallery
    }

    private var viewModel: ItemDetailViewModel? { state.detailViewModel }
    private var item: TrackerItem? { viewModel?.item }
    private var imageAttachments: [TrackerAttachment] {
        guard let item else { return [] }
        return (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
    }
    private var galleryPreviewBinding: Binding<GalleryPreview?> {
        Binding(get: { state.detailGalleryPreview }, set: { state.detailGalleryPreview = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let viewModel, let item, state.detailItemID == itemID {
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
                            originTitle: item.originConvoID == currentConvoID ? nil : state.detailOriginTitle,
                            availableResolutions: viewModel.availableResolutions, isBusy: viewModel.isBusy),
                        draft: Binding(get: { viewModel.draft }, set: { viewModel.draft = $0 }),
                        image: { state.detailImages[$0.blobRef] },
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
            if case let .recording(start) = state.detailRecorder.state {
                voiceRecordingBar(start: start)
            }
        }
        .navigationTitle("")
        .task(id: itemID) {
            // I6: only (re)create the detail VM when navigating to a
            // genuinely different item. A rebuild of this host for the
            // SAME item (e.g. the width-crossing branch move in
            // `MacChatView`) must not drop the in-flight draft/recording —
            // there's no host-local `@State` left to lose; everything
            // lives on `state`, which survives the rebuild untouched when
            // this guard is a no-op.
            guard state.detailItemID != itemID, let deps else { return }
            state.detailViewModel?.stop()
            state.detailImages = [:]
            state.detailOriginTitle = nil
            state.detailGalleryPreview = nil
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            state.detailItemID = itemID
            state.detailViewModel = vm
            vm.start()
        }
        .task(id: imageAttachments.map(\.blobRef)) {
            guard let deps else { return }
            let media = deps.mediaService(for: session)
            for attachment in imageAttachments where state.detailImages[attachment.blobRef] == nil {
                guard let image = await media.swiftUIImage(for: mediaURL(attachment)) else { continue }
                state.detailImages[attachment.blobRef] = image
            }
        }
        .task(id: item?.originConvoID) {
            guard let convoID = item?.originConvoID, let deps else { state.detailOriginTitle = nil; return }
            state.detailOriginTitle = (try? deps.journalStore(for: session).conversation(id: convoID))?.title
        }
        // I7: the detail VM's own errors (a failed close/reopen/comment)
        // were previously never surfaced on Mac — the only alert in this
        // file is bound to the PANEL VM's `error`. Mirrors iOS
        // `ItemDetailHost`'s alert, bound to `state.detailViewModel`.
        .alert("Tracker", isPresented: Binding(
            get: { state.detailViewModel?.error != nil },
            set: { if !$0 { state.detailViewModel?.error = nil } }
        )) {
            Button("OK") { state.detailViewModel?.error = nil }
        } message: {
            Text(state.detailViewModel?.error ?? "")
        }
        // No `onDisappear` teardown here on purpose (I6): a width-crossing
        // rebuild tears this host down and immediately rebuilds it for the
        // SAME item, and an unconditional stop() here would race that
        // rebuild's `.task(id: itemID)` (which is a no-op for a matching
        // id) and kill the VM out from under it. Teardown instead happens
        // in `MacChatView`'s outer `onDisappear`, which only fires on a
        // genuine room-leave — see its comment.
        .sheet(item: galleryPreviewBinding) { preview in
            AttachmentFullscreenViewer(gallery: preview.gallery, onDismiss: { state.detailGalleryPreview = nil })
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
    /// `NSWorkspace.open`). C2/I9 (temp-file/attachment code): left as-is
    /// per the coordinator's instruction — part 2 switches this to a
    /// shared helper.
    private func openAttachment(_ a: TrackerAttachment, in item: TrackerItem) {
        guard let deps else { return }
        if a.isImage {
            let all = (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
            let urls = all.map(mediaURL)
            state.detailGalleryPreview = GalleryPreview(gallery: ImageGalleries.urls(urls, tapped: mediaURL(a), deps: deps, session: session))
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
            do { try await state.detailRecorder.start() }
            catch { state.detailViewModel?.error = error.localizedDescription }
        }
    }

    private func voiceRecordingBar(start: Date) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(start, style: .timer).monospacedDigit()
            Spacer()
            Button("Cancel") { state.detailRecorder.cancel() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button {
                guard let result = state.detailRecorder.stop() else { return }
                Task { await state.detailViewModel?.sendVoiceNote(url: result.url) }
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.bar)
    }
}

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
    /// `blobRef`s currently being fetched — a second tap on the same
    /// attachment while its first fetch is still in flight is ignored
    /// rather than starting a duplicate download.
    var detailFetchingBlobRefs: Set<String> = []
    /// `ItemReadMemory.wasAtBottom(itemID:)` for whichever item is
    /// currently pushed — read once when `detailItemID` is (re)assigned
    /// (`.task(id: itemID)`'s guard block) and handed to `ItemDetailView`
    /// as `startsAtBottom`. Lives here rather than host-local `@State`
    /// for the same reason `detailItemID` does: `MacItemDetailHost` swaps
    /// items in place (same `ItemDetailView` call site, new `model.item`),
    /// which SwiftUI treats as the same view identity, so host-local
    /// `@State` wouldn't reliably reset per item.
    var detailStartsAtBottom = false
    /// Latest bottom-visibility the comment thread reported for the
    /// currently pushed item (`ItemDetailView.onBottomVisibilityChange`).
    /// Persisted to `ItemReadMemory` on item-id change and on disappear.
    var detailIsAtBottom = false

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
                        originTitles: state.originTitles, isSupported: viewModel.isSupported, isRefreshing: viewModel.isRefreshing,
                        // Fix wave part 2, item C: outbox "create" rows not
                        // yet confirmed by the server.
                        pending: viewModel.pendingCreates.map {
                            ItemsListView.PendingRow(id: $0.id, kind: $0.kind, title: $0.title, isFailed: $0.lastError != nil, error: $0.lastError)
                        }),
                    scope: Binding(get: { viewModel.scope }, set: { viewModel.scope = $0 }),
                    convoID: viewModel.convoID,
                    thumbnail: { _ in nil },
                    onSelect: { state.path.append($0.id) },
                    onMove: { id, index in Task { await viewModel.move(itemID: id, toIndex: index) } },
                    onCreate: { state.showCreate = true },
                    onOpenConversation: handleOpenConversation)
                .navigationDestination(for: String.self) { id in
                    MacItemDetailHost(itemID: id, session: session, currentConvoID: viewModel.convoID,
                                       state: state, onOpenConversation: handleOpenConversation,
                                       // Per-host PUSH: an item link inside
                                       // an item stacks over it, so Back
                                       // returns to where the link was
                                       // tapped (item #115, fix round 2 —
                                       // this used to REPLACE the path).
                                       onOpenItem: { state.path.append($0) })
                }
            }
        }
        .sheet(isPresented: Binding(get: { state.showCreate }, set: { state.showCreate = $0 })) {
            NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } }
        }
        .task(id: viewModel.scope) {
            // Labels for the "All" scope rows come from the local store's
            // conversation list — one cheap read per scope switch (ruling
            // 2: no per-conversation round trip, `ItemsListView` already
            // falls back to "Another chat" for a miss).
            guard let deps else { return }
            state.originTitles = (try? deps.journalStore(for: session).conversationOriginLabels()) ?? [:]
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
    /// iOS `ItemDetailHost.currentConvoID`). Optional since the app
    /// shell's Decisions instance has no home conversation (spec §1).
    let currentConvoID: String?
    let state: MacItemsPaneState
    let onOpenConversation: (String) -> Void
    /// Opens ANOTHER tracker item — a `[#12](matron://item/12)` link in this
    /// item's body, a comment, or a link chip (#115). The surface decides
    /// what "open" means: the items pane PUSHES onto its own
    /// `MacItemsPaneState.path` (so Back returns to the item the link was
    /// tapped in), Decisions re-selects (it has no stack). `nil` leaves item
    /// links inert — never handed to the OS either way.
    var onOpenItem: ((String) -> Void)? = nil
    @Environment(\.appDependencies) private var deps
    /// `[#12](matron://item/12)` taps inside this item. This host installs
    /// its OWN handler (shadowing the surface's) so the link resolves
    /// against this stack — see `trackerItemLinks` below.
    @State private var itemLinkRelay = TrackerItemLinkRelay()
    /// Hover state for the "Drop here to add" overlay while a drag is over
    /// the detail pane — mirrors `MacChatView.isDropTargeted`, but scoped
    /// to this host (no stuck-overlay watchdog: `ComposerDropDelegate`'s
    /// delegate-based `.onDrop` isn't reused here, so there's no lingering
    /// drag session to lose `dropExited` — see `attachDroppedFiles(_:)`).
    @State private var isDropTargeted = false

    /// Identifiable wrapper so `.sheet(item:)` has something to key on —
    /// `ImageGallery` itself isn't `Identifiable` (same pattern as
    /// `MacChatView.ImagePreview`).
    struct GalleryPreview: Identifiable {
        let id = UUID()
        let gallery: ImageGallery
    }

    /// A tapped link chip (`item.links`). Routed through the same policy as
    /// message bodies so an item link works here too — and so no `matron://`
    /// URL reaches `NSWorkspace`, which has no handler for the scheme.
    private func openLink(_ url: URL) {
        switch MatronItemLink.action(for: url) {
        case .openTrackerItem(let number): Task { await openTrackerItem(num: number) }
        case .swallow: break
        case .system(let url): NSWorkspace.shared.open(url)
        }
    }

    /// A tapped `matron://item/<n>` link in this item's body, a comment or a
    /// link chip, resolved by the shared `TrackerItemLinkResolver`: a known
    /// number opens through `onOpenItem`, a number this device still doesn't
    /// have leaves this item exactly where it is and says so in the tracker
    /// alert (item #115, fix round 2).
    @MainActor private func openTrackerItem(num: Int) async {
        guard let deps else { return }
        switch await deps.itemLinkResolver(for: session).resolve(num: num) {
        case .open(let id):
            // A link to the item already on screen is a no-op, not a second
            // identical push.
            guard id != itemID else { return }
            onOpenItem?(id)
        case let miss:
            itemLinkRelay.alert = miss.alertMessage(num: num)
        }
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
                            availableResolutions: viewModel.availableResolutions, isBusy: viewModel.isBusy,
                            loadedCommentCount: viewModel.loadedCommentCount),
                        draft: Binding(get: { viewModel.draft }, set: { viewModel.draft = $0 }),
                        image: { state.detailImages[$0.blobRef] },
                        onOpenAttachment: { openAttachment($0, in: item) },
                        onOpenLink: { openLink($0) },
                        onOpenConversation: onOpenConversation,
                        onSubmit: { Task { await viewModel.submitComment(attachments: []) } },
                        // Fix wave part 2, item B: attach must post an
                        // attachment-only comment (empty body, draft
                        // untouched) via `submitAttachments`, not
                        // `submitComment(attachments:)` — the Send button
                        // above keeps owning `submitComment` for the
                        // draft-as-body path.
                        onAttach: { pickFiles { urls in Task { await attachFiles(urls) } } },
                        onVoiceNote: { startVoiceNote() },
                        onClose: { r in Task { await viewModel.close(resolution: r, comment: nil) } },
                        onReopen: { Task { await viewModel.reopen() } },
                        startsAtBottom: state.detailStartsAtBottom,
                        // Both follow the live position (Bugbot, PR #198): a
                        // width-crossing rebuild remounts this host for the
                        // SAME item, and its fresh ItemDetailView must place
                        // itself where the reader actually is, not where the
                        // item was first opened.
                        onBottomVisibilityChange: { state.detailIsAtBottom = $0; state.detailStartsAtBottom = $0 })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if case let .recording(start) = state.detailRecorder.state {
                voiceRecordingBar(start: start)
            }
            // C2/I9: coarse "something is downloading" affordance — not
            // per-row, since `AttachmentFile`'s row (in `ItemDetailView`,
            // DesignSystem, out of scope for this file) takes no loading
            // parameter to hang a per-row spinner off of.
            if !state.detailFetchingBlobRefs.isEmpty {
                fetchingBar()
            }
        }
        .navigationTitle("")
        // Item links inside this item's body / comments / link chips
        // (#115) — one install for this whole host, shadowing the
        // surface's so the link resolves against THIS host's navigation.
        .trackerItemLinks(itemLinkRelay) { await openTrackerItem(num: $0) }
        // Keyed on the pane's TOP OF STACK as well as this host's own item,
        // because an item link now PUSHES a second host over this one
        // (item #115, fix round 2). `.task` does not re-fire when a view
        // reappears from under a pop, and the detail state on `state` is
        // single-slot — so without this re-key, going Back would leave the
        // item underneath rendering its placeholder forever. `state.path`
        // is `@Observable`, so a push or pop re-evaluates this body and
        // re-runs the task with a new id.
        .task(id: "\(itemID)\u{1}\(state.path.last ?? "")") {
            // Only the item on top owns the single detail slot; a host
            // buried under a push must not steal it back. An empty path is
            // the stackless Decisions surface, where this host is always
            // the one on screen.
            guard state.path.isEmpty || state.path.last == itemID else { return }
            // I6: only (re)create the detail VM when navigating to a
            // genuinely different item. A rebuild of this host for the
            // SAME item (e.g. the width-crossing branch move in
            // `MacChatView`) must not drop the in-flight draft/recording —
            // there's no host-local `@State` left to lose; everything
            // lives on `state`, which survives the rebuild untouched when
            // this guard is a no-op.
            guard state.detailItemID != itemID, let deps else { return }
            // Persist the OUTGOING item's read position before swapping —
            // this host swaps items in place rather than tearing down and
            // rebuilding (I6), so this guard body is the only reliable
            // "leaving this item" signal; `.onDisappear` below only fires
            // on a genuine pane close, not an in-place navigation.
            if let previousItemID = state.detailItemID {
                ItemReadMemory().store(itemID: previousItemID, atBottom: state.detailIsAtBottom)
            }
            state.detailViewModel?.stop()
            state.detailImages = [:]
            state.detailOriginTitle = nil
            state.detailGalleryPreview = nil
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            state.detailItemID = itemID
            state.detailStartsAtBottom = ItemReadMemory().wasAtBottom(itemID: itemID)
            state.detailIsAtBottom = state.detailStartsAtBottom
            state.detailViewModel = vm
            vm.start()
        }
        // Belt-and-braces for the LAST item viewed in a pane close/window
        // teardown, which the in-place swap above never sees (there's no
        // "next" item to trigger its guard). Guarded because a PUSH also
        // disappears this host: by then the slot (and `detailIsAtBottom`)
        // belongs to the item on top, and the activation above has already
        // persisted ours.
        .onDisappear {
            guard state.detailItemID == itemID else { return }
            ItemReadMemory().store(itemID: itemID, atBottom: state.detailIsAtBottom)
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
            state.detailOriginTitle = try? deps.journalStore(for: session).conversationOriginLabel(id: convoID)
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
        // No VM-teardown `onDisappear` here on purpose (I6): a width-crossing
        // rebuild tears this host down and immediately rebuilds it for the
        // SAME item, and an unconditional stop() here would race that
        // rebuild's `.task(id: itemID)` (which is a no-op for a matching
        // id) and kill the VM out from under it. Teardown instead happens
        // in `MacChatView`'s outer `onDisappear`, which only fires on a
        // genuine room-leave — see its comment. The `.onDisappear` added
        // above is unrelated: it only persists `ItemReadMemory`, which is
        // idempotent and safe to run on every teardown, including a
        // same-item rebuild.
        .sheet(item: galleryPreviewBinding) { preview in
            AttachmentFullscreenViewer(gallery: preview.gallery, onDismiss: { state.detailGalleryPreview = nil })
        }
        // Drag-and-drop attachments over the whole detail pane, mirroring
        // `MacChatView`'s chat-column drop zone (Task: tracker composer
        // parity). Resolves each provider through `ComposerDropDelegate`'s
        // shared static loader rather than duplicating it, then posts the
        // result as an attachment-only comment via the same `attachFiles(_:)`
        // the paperclip picker uses.
        .onDrop(of: ComposerDropDelegate.acceptedTypes, isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            Task { await attachDroppedFiles(providers) }
            return true
        }
        .overlay {
            if isDropTargeted {
                DropHereOverlay(subtitle: "Files and images will be attached to this item")
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
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
    /// safe temp file (`AttachmentTempFiles.write`, fix wave part 2 item
    /// H/C2/I9 — namespaced by a digest of `blobRef` so two attachments
    /// sharing a display name never collide, and the raw name is
    /// sanitised against path traversal) and hands it to the user's
    /// default app.
    ///
    /// `detailFetchingBlobRefs` guards against a double-click starting a
    /// second concurrent download of the same attachment.
    /// `AttachmentTempFiles.existingFile(name:blobRef:)` is the reuse
    /// check — it recomputes `write`'s own destination formula (one
    /// source of truth, in `AttachmentTempFiles` itself) and confirms the
    /// file is still on disk, so a hit skips the network fetch entirely;
    /// a miss (e.g. the OS reaped the temp dir between launches) just
    /// falls through to a normal re-fetch rather than being an error. Do
    /// NOT reconstruct the digest/path formula here — see that function's
    /// doc comment.
    private func openAttachment(_ a: TrackerAttachment, in item: TrackerItem) {
        guard let deps else { return }
        if a.isImage {
            let all = (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
            let urls = all.map(mediaURL)
            state.detailGalleryPreview = GalleryPreview(gallery: ImageGalleries.urls(urls, tapped: mediaURL(a), deps: deps, session: session))
            return
        }
        if let existing = AttachmentTempFiles.existingFile(name: a.name, blobRef: a.blobRef) {
            NSWorkspace.shared.open(existing)
            return
        }
        guard !state.detailFetchingBlobRefs.contains(a.blobRef) else { return }
        state.detailFetchingBlobRefs.insert(a.blobRef)
        Task {
            defer { state.detailFetchingBlobRefs.remove(a.blobRef) }
            guard let data = await deps.mediaService(for: session).fetchBytes(mxcURL: mediaURL(a)) else {
                state.detailViewModel?.error = "Couldn't download \(a.name.isEmpty ? "that attachment" : a.name)."
                return
            }
            do {
                let url = try AttachmentTempFiles.write(data, name: a.name, blobRef: a.blobRef)
                NSWorkspace.shared.open(url)
            } catch {
                // Do NOT open on a write failure — there's nothing valid
                // to hand `NSWorkspace`.
                state.detailViewModel?.error = error.localizedDescription
            }
        }
    }

    /// Hands back the picked URLs only — reading their bytes is the
    /// caller's job (`attachFiles`), off the main queue.
    private func pickFiles(_ done: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            done(panel.urls)
        }
    }

    /// Fix wave part 2 (minor): reads each picked file's bytes off the
    /// main queue (`Task.detached` — `pickFiles`'s old inline
    /// `Data(contentsOf:)` in the panel's completion handler ran
    /// synchronously on main) and caps at 25 MB/file; an oversized file is
    /// skipped with `vm.error` set rather than silently dropped or
    /// blocking the UI while it reads. Successfully-read files are handed
    /// to `submitAttachments` (item B) as one attachment-only comment.
    private static let maxAttachmentBytes = 25 * 1024 * 1024

    /// `Result`'s failure type must conform to `Error` — a plain `String`
    /// doesn't, hence this tiny wrapper rather than `Result<Data, String>`.
    private struct AttachmentReadFailure: Error { let message: String }

    /// Resolves each dropped `NSItemProvider` to a local URL via
    /// `ComposerDropDelegate`'s shared static loader (the same one the
    /// chat column's drop zone uses — not duplicated here), then hands the
    /// successfully-resolved URLs to `attachFiles(_:)`. Mirrors
    /// `ComposerDropDelegate.performDrop`'s "some good, some bad providers
    /// still attaches the good ones" behaviour; load failures are silently
    /// skipped rather than surfaced — `attachFiles`/`readCapped` already
    /// owns the user-visible error channel for this pane (`viewModel.error`),
    /// and a provider that fails to resolve to a URL at all never reaches it.
    private func attachDroppedFiles(_ providers: [NSItemProvider]) async {
        var urls: [URL] = []
        for provider in providers {
            if case .success(let url) = await ComposerDropDelegate.loadURL(from: provider) {
                urls.append(url)
            }
        }
        guard !urls.isEmpty else { return }
        await attachFiles(urls)
    }

    private func attachFiles(_ urls: [URL]) async {
        guard let viewModel = state.detailViewModel else { return }
        var staged: [(data: Data, name: String, mime: String)] = []
        for url in urls {
            switch await Self.readCapped(url) {
            case .success(let data):
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                staged.append((data, url.lastPathComponent, mime))
            case .failure(let failure):
                viewModel.error = failure.message
            }
        }
        guard !staged.isEmpty else { return }
        _ = await viewModel.submitAttachments(staged)
    }

    /// Off-main file read with a size cap, run via `Task.detached` so the
    /// synchronous `Data(contentsOf:)` never blocks the main actor this
    /// view lives on.
    private static func readCapped(_ url: URL) async -> Result<Data, AttachmentReadFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<Data, AttachmentReadFailure> in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attrs?[.size] as? Int
            if let size, size > maxAttachmentBytes {
                return .failure(AttachmentReadFailure(message: "\(url.lastPathComponent) is larger than 25 MB and wasn't attached."))
            }
            do {
                return .success(try Data(contentsOf: url))
            } catch {
                return .failure(AttachmentReadFailure(message: "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"))
            }
        }.value
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

    /// C2/I9: coarse download-in-progress affordance — see the doc comment
    /// on `openAttachment` for why this isn't per-row.
    private func fetchingBar() -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Downloading attachment…").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(8)
        .background(.bar)
    }
}

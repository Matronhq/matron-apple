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

    /// One recorder shared across whichever item is open — mirrors the
    /// single-recorder-per-host design from before hoisting.
    let detailRecorder = VoiceRecorder()

    /// The item a recording in `detailRecorder` belongs to, set the moment
    /// `start()` actually succeeds and read (then cleared) when the bar's
    /// stop button fires (CodeRabbit Major, #115 fix round 7). Item-link
    /// navigation (a push in the pane, a re-selection in Decisions) moves
    /// which item's `MacItemDetailHost` is on screen WITHOUT touching the
    /// recorder — it is deliberately not cancelled, so a user can navigate
    /// away and back without losing an in-progress note. Resolving the
    /// completion against this stored owner, rather than "whichever slot
    /// is active right now", is what stops a recording begun on item A
    /// from being attached to item B after such a navigation. If the
    /// owning slot is gone by the time the recording stops (its item fell
    /// off the stack), the result is dropped rather than guessed at.
    var recordingItemID: String?

    /// Cancels any in-flight recording and forgets which item it belonged
    /// to, in one place — every call site that cancels the recorder
    /// (teardown, the bar's own Cancel button) needs both halves done
    /// together, or a stale `recordingItemID` could outlive the recording
    /// it named.
    func cancelRecording() {
        detailRecorder.cancel()
        recordingItemID = nil
    }

    /// Called by every navigation that can change which item is on
    /// screen — a push, an item-link re-select, a Decisions row click —
    /// BEFORE the navigation itself commits (item #115, fix round 8,
    /// controller ruling: a recording belongs to the item it started on,
    /// and navigating away from that item ENDS it visibly). A no-op if
    /// nothing is recording, or if `itemID` IS the item already being
    /// recorded — a same-item re-navigation (e.g. re-clicking the
    /// currently-selected Decisions row) must not kill it out from under
    /// the user.
    func cancelRecordingIfNavigating(to itemID: String) {
        guard let recordingItemID, recordingItemID != itemID else { return }
        cancelRecording()
    }

    /// Detail state, ONE SLOT PER ITEM currently reachable on this surface
    /// — every item on `path`, or (on the stackless Decisions surface) just
    /// the selected one.
    ///
    /// This was a single slot until item links made the pane a real stack
    /// (#115). With one slot, pushing #12 over #9 overwrote #9's
    /// `ItemDetailViewModel`, and Back rebuilt it from scratch — silently
    /// throwing away the half-typed comment in `ItemDetailViewModel.draft`,
    /// the only place that text lives. Keyed slots mean a pop finds the
    /// SAME view model, draft and all.
    private(set) var slots: [String: MacItemDetailSlot] = [:]

    /// Where released slots persist their read position. Injectable so
    /// tests exercise slot lifetime without writing to the real defaults.
    let readMemory: ItemReadMemory

    init(readMemory: ItemReadMemory = ItemReadMemory()) {
        self.readMemory = readMemory
    }

    /// This item's slot, created on first push. Never recycles another
    /// item's — call it from `.task`, not from `body` (it mutates).
    func slot(for itemID: String) -> MacItemDetailSlot {
        if let existing = slots[itemID] { return existing }
        let fresh = MacItemDetailSlot(itemID: itemID)
        slots[itemID] = fresh
        return fresh
    }

    /// Drops every slot whose item is no longer reachable — stopping its
    /// view model and persisting its read position, the two things the old
    /// single-slot swap did inline. `retained` is the stack (or, stackless,
    /// the one selected item).
    func releaseSlots(keeping retained: Set<String>) {
        for (id, slot) in slots where !retained.contains(id) {
            slot.viewModel?.stop()
            readMemory.store(itemID: id, atBottom: slot.isAtBottom)
            slots[id] = nil
            // A slot released while it owns the in-flight recording (its
            // item fell off the stack, or a surface re-selected away from
            // it without going through `cancelRecordingIfNavigating`)
            // must end that recording rather than leave it running with
            // no slot left to attach the result to — the bar itself only
            // renders on the host whose id equals `recordingItemID`, so a
            // released owner would make the recording invisible, not
            // merely hidden (#115, fix round 8).
            if recordingItemID == id { cancelRecording() }
        }
    }

    /// Surface teardown (pane close, window teardown, nav switch).
    func releaseAllSlots() {
        releaseSlots(keeping: [])
    }

    /// The slot a detail host's activation should populate, or `nil` when
    /// that host is NOT on screen and must build nothing.
    ///
    /// A pane host's `.task` is keyed on the top of the stack, so popping
    /// back to the LIST re-fires it for the host that was just popped
    /// (Bugbot, #115 round 4). Reading "empty path" as "this host is
    /// visible" was only ever true for the stackless Decisions surface, so
    /// the two are now told apart explicitly: on a path-driven surface only
    /// the item on top may activate, and release is left entirely to
    /// `MacItemsPane`'s `onChange(of: path)` so there is a single owner of
    /// it. The stackless surface has no path to observe, so its one visible
    /// host both activates and releases.
    func activateSlot(for itemID: String, surface: MacItemDetailSurface) -> MacItemDetailSlot? {
        switch surface {
        case .stack:
            guard path.last == itemID else { return nil }
        case .stackless:
            releaseSlots(keeping: [itemID])
        }
        return slot(for: itemID)
    }
}

/// How a `MacItemDetailHost`'s surface navigates — the two are NOT
/// interchangeable when deciding whether a host is still on screen.
enum MacItemDetailSurface {
    /// The items pane: `MacItemsPaneState.path` is a real navigation stack,
    /// and a host is on screen only while its item is on top of it.
    case stack
    /// Decisions (Mac chat list): list + detail, no stack. `path` stays
    /// empty; the single host is on screen whenever it exists.
    case stackless
}

/// Everything `MacItemDetailHost` needs for ONE item, so two hosts on the
/// same stack can't tread on each other. Reference type: hosts read and
/// write it in place, and `@Observable` so those writes still drive the
/// view (`MacItemsPaneState`'s own observation stops at the dictionary).
@MainActor @Observable
final class MacItemDetailSlot {
    let itemID: String
    var viewModel: ItemDetailViewModel?
    var images: [String: Image] = [:]
    var galleryPreview: MacItemDetailHost.GalleryPreview?
    var originTitle: String?
    /// `blobRef`s currently being fetched — a second tap on the same
    /// attachment while its first fetch is still in flight is ignored
    /// rather than starting a duplicate download.
    var fetchingBlobRefs: Set<String> = []
    /// `ItemReadMemory.wasAtBottom(itemID:)`, read once when the slot is
    /// created and handed to `ItemDetailView` as `startsAtBottom`.
    var startsAtBottom = false
    /// Latest bottom-visibility the comment thread reported. Persisted to
    /// `ItemReadMemory` when the slot is released.
    var isAtBottom = false

    init(itemID: String) { self.itemID = itemID }
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
                                       // Ends any in-flight recording that
                                       // belongs to a DIFFERENT item before
                                       // the push commits (fix round 8) —
                                       // `releaseSlots` (driven by the
                                       // `path` change below) would also
                                       // catch it, but only after this
                                       // host has already been asked to
                                       // draw the newly-pushed item.
                                       onOpenItem: { id in
                                           state.cancelRecordingIfNavigating(to: id)
                                           state.path.append(id)
                                       },
                                       surface: .stack)
                }
            }
        }
        .sheet(isPresented: Binding(get: { state.showCreate }, set: { state.showCreate = $0 })) {
            NewItemSheet { kind, title, body in Task { await viewModel.create(kind: kind, title: title, body: body) } }
        }
        // Slots are kept alive for everything ON the stack so Back restores
        // an item's view model (and its draft) instead of rebuilding it —
        // so the stack shrinking is what frees them. Covers the case no
        // host's `.task` can: popping all the way back to the LIST, where
        // no detail host is left to run anything.
        .onChange(of: state.path) { _, path in
            state.releaseSlots(keeping: Set(path))
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

/// Item detail push destination. Reads/writes everything through its slot
/// in the shared `MacItemsPaneState` (I6) rather than owning its own
/// `@State` — see that type's doc comment for why.
/// `deps.makeItemDetailViewModel` is called only when this item's slot
/// has no view model yet: a rebuild for the SAME item, or a pop back to an
/// item still on the stack, finds everything already populated (draft
/// included). Image loading and the voice-note recorder follow the same
/// "read/write through the slot" shape; the recorder itself stays shared,
/// one per surface.
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
    /// Whether this host lives on a navigation stack (`MacItemsPane`) or on
    /// the stackless Decisions surface — see `MacItemDetailSurface`. Drives
    /// activation: a stack host that is no longer on top must not run.
    let surface: MacItemDetailSurface
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
        // Through the relay, not straight to `openTrackerItem`: a chip tap
        // is a tap like any other and must share the body's staleness gate
        // (item #115, fix round 5).
        case .openTrackerItem(let number): itemLinkRelay.action(number)
        case .swallow: break
        case .system(let url): NSWorkspace.shared.open(url)
        }
    }

    /// A tapped `matron://item/<n>` link in this item's body, a comment or a
    /// link chip, resolved by the shared `TrackerItemLinkResolver`: a known
    /// number opens through `onOpenItem`, a number this device still doesn't
    /// have leaves this item exactly where it is and says so in the tracker
    /// alert (item #115, fix round 2).
    @MainActor private func openTrackerItem(num: Int) async -> TrackerItemLinkOutcome {
        guard let deps else { return .ignore }
        let outcome = await deps.trackerItemLinkOutcome(num: num, session: session)
        // A link to the item already on screen is a no-op, not a second
        // identical push.
        if case .open(let id) = outcome, id == itemID { return .ignore }
        return outcome
    }

    /// This host's own slot — `nil` until its `.task` creates it. A
    /// non-creating read, because `body` must not mutate `state`.
    private var slot: MacItemDetailSlot? { state.slots[itemID] }
    private var viewModel: ItemDetailViewModel? { slot?.viewModel }
    private var item: TrackerItem? { viewModel?.item }
    private var imageAttachments: [TrackerAttachment] {
        guard let item else { return [] }
        return (item.attachments + (viewModel?.comments.flatMap(\.attachments) ?? [])).filter(\.isImage)
    }
    private var galleryPreviewBinding: Binding<GalleryPreview?> {
        Binding(get: { slot?.galleryPreview }, set: { slot?.galleryPreview = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let slot, let viewModel = slot.viewModel, let item = viewModel.item {
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
                            originTitle: item.originConvoID == currentConvoID ? nil : slot.originTitle,
                            availableResolutions: viewModel.availableResolutions, isBusy: viewModel.isBusy,
                            loadedCommentCount: viewModel.loadedCommentCount),
                        draft: Binding(get: { viewModel.draft }, set: { viewModel.draft = $0 }),
                        image: { slot.images[$0.blobRef] },
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
                        startsAtBottom: slot.startsAtBottom,
                        // Both follow the live position (Bugbot, PR #198): a
                        // width-crossing rebuild remounts this host for the
                        // SAME item, and its fresh ItemDetailView must place
                        // itself where the reader actually is, not where the
                        // item was first opened.
                        onBottomVisibilityChange: { slot.isAtBottom = $0; slot.startsAtBottom = $0 })
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            // Gated on THIS host's item owning the recording (#115, fix
            // round 8) — `detailRecorder.state` alone says nothing about
            // WHICH item started it, so without this a recording begun on
            // A rendered its bar over whichever host was on screen when
            // the state was read, including a host for a completely
            // different item B.
            if state.recordingItemID == itemID, case let .recording(start) = state.detailRecorder.state {
                voiceRecordingBar(start: start)
            }
            // C2/I9: coarse "something is downloading" affordance — not
            // per-row, since `AttachmentFile`'s row (in `ItemDetailView`,
            // DesignSystem, out of scope for this file) takes no loading
            // parameter to hang a per-row spinner off of.
            if !(slot?.fetchingBlobRefs.isEmpty ?? true) {
                fetchingBar()
            }
        }
        .navigationTitle("")
        // Item links inside this item's body / comments / link chips
        // (#115) — one install for this whole host, shadowing the
        // surface's so the link resolves against THIS host's navigation.
        .trackerItemLinks(itemLinkRelay, resolve: { await openTrackerItem(num: $0) },
                          open: { onOpenItem?($0) })
        // Keyed on the pane's TOP OF STACK as well as this host's own item,
        // because an item link now PUSHES a second host over this one
        // (item #115, fix round 2). `.task` does not re-fire when a view
        // reappears from under a pop, so without this re-key going Back
        // would leave the item underneath rendering its placeholder
        // forever. `state.path` is `@Observable`, so a push or pop
        // re-evaluates this body and re-runs the task with a new id — and
        // that includes the host being popped, which is why the body's
        // first job is to ask whether it is still on screen at all.
        .task(id: "\(itemID)\u{1}\(state.path.last ?? "")") {
            // `activateSlot` decides whether this host is still on screen —
            // on a stack, only the item on top is, INCLUDING when the pop
            // that removed this host emptied the path (Bugbot, #115 round
            // 4: an empty path used to read as "the Decisions surface", so
            // a popped host resurrected its slot and started a fresh view
            // model behind the list). It also owns the stackless surface's
            // release; the pane's own `onChange(of: path)` owns the stack's.
            guard let slot = state.activateSlot(for: itemID, surface: surface), let deps else { return }
            // I6 + item #115: a live view model means either a rebuild of
            // this same push (the width-crossing branch move in
            // `MacChatView`) or a pop back to an item still on the stack.
            // Either way there is nothing to build — and rebuilding would
            // silently discard `ItemDetailViewModel.draft`, the only place
            // a half-typed comment lives.
            guard slot.viewModel == nil else { return }
            slot.startsAtBottom = state.readMemory.wasAtBottom(itemID: itemID)
            slot.isAtBottom = slot.startsAtBottom
            let vm = deps.makeItemDetailViewModel(for: session, itemID: itemID)
            slot.viewModel = vm
            vm.start()
        }
        // Belt-and-braces for the LAST item viewed in a pane close/window
        // teardown, which the in-place swap above never sees (there's no
        // "next" item to trigger its guard). Guarded because a PUSH also
        // disappears this host: by then the slot (and `detailIsAtBottom`)
        // belongs to the item on top, and the activation above has already
        // persisted ours.
        .onDisappear {
            // A pop already released this slot (and stored its position);
            // a push leaves it alive and owning its own `isAtBottom`.
            guard let slot else { return }
            state.readMemory.store(itemID: itemID, atBottom: slot.isAtBottom)
        }
        .task(id: imageAttachments.map(\.blobRef)) {
            guard let deps else { return }
            let media = deps.mediaService(for: session)
            for attachment in imageAttachments where slot?.images[attachment.blobRef] == nil {
                guard let image = await media.swiftUIImage(for: mediaURL(attachment)) else { continue }
                slot?.images[attachment.blobRef] = image
            }
        }
        .task(id: item?.originConvoID) {
            guard let convoID = item?.originConvoID, let deps else { slot?.originTitle = nil; return }
            slot?.originTitle = try? deps.journalStore(for: session).conversationOriginLabel(id: convoID)
        }
        // I7: the detail VM's own errors (a failed close/reopen/comment)
        // were previously never surfaced on Mac — the only alert in this
        // file is bound to the PANEL VM's `error`. Mirrors iOS
        // `ItemDetailHost`'s alert, bound to this slot's view model.
        .alert("Tracker", isPresented: Binding(
            get: { slot?.viewModel?.error != nil },
            set: { if !$0 { slot?.viewModel?.error = nil } }
        )) {
            Button("OK") { slot?.viewModel?.error = nil }
        } message: {
            Text(slot?.viewModel?.error ?? "")
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
            AttachmentFullscreenViewer(gallery: preview.gallery, onDismiss: { slot?.galleryPreview = nil })
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
            slot?.galleryPreview = GalleryPreview(gallery: ImageGalleries.urls(urls, tapped: mediaURL(a), deps: deps, session: session))
            return
        }
        if let existing = AttachmentTempFiles.existingFile(name: a.name, blobRef: a.blobRef) {
            NSWorkspace.shared.open(existing)
            return
        }
        guard let slot, !slot.fetchingBlobRefs.contains(a.blobRef) else { return }
        slot.fetchingBlobRefs.insert(a.blobRef)
        Task {
            defer { slot.fetchingBlobRefs.remove(a.blobRef) }
            guard let data = await deps.mediaService(for: session).fetchBytes(mxcURL: mediaURL(a)) else {
                slot.viewModel?.error = "Couldn't download \(a.name.isEmpty ? "that attachment" : a.name)."
                return
            }
            do {
                let url = try AttachmentTempFiles.write(data, name: a.name, blobRef: a.blobRef)
                NSWorkspace.shared.open(url)
            } catch {
                // Do NOT open on a write failure — there's nothing valid
                // to hand `NSWorkspace`.
                slot.viewModel?.error = error.localizedDescription
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
        guard let viewModel = slot?.viewModel else { return }
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
            do {
                try await state.detailRecorder.start()
                // Recorded only AFTER a successful start, so a throw (e.g.
                // `.alreadyRecording` from a second host's mic tap) never
                // steals ownership from whichever item is actually
                // recording (#115, fix round 7).
                state.recordingItemID = itemID
            }
            catch { slot?.viewModel?.error = error.localizedDescription }
        }
    }

    private func voiceRecordingBar(start: Date) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            Text(start, style: .timer).monospacedDigit()
            Spacer()
            Button("Cancel") { state.cancelRecording() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Button {
                guard let result = state.detailRecorder.stop() else { return }
                // Resolve against the item that OWNS this recording, not
                // whichever host's button happened to be on screen when
                // the user tapped stop — an item link or a Decisions
                // re-selection since `startVoiceNote` moves the active
                // slot without touching the recorder (#115, fix round 7).
                // If that item's slot is gone (it fell off the stack
                // mid-recording), the result is dropped rather than
                // guessed onto whatever is on screen now.
                let owningItemID = state.recordingItemID
                state.recordingItemID = nil
                guard let owningItemID, let ownerSlot = state.slots[owningItemID] else { return }
                Task { await ownerSlot.viewModel?.sendVoiceNote(url: result.url) }
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

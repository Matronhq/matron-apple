import SwiftUI
import UniformTypeIdentifiers
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem
import os

/// Diagnostic logger for the chat paginate trigger plumbing. Calls
/// to `paginateLogger.diag(...)` are gated by `MatronDebug.enabled`
/// so they stay in the source as living documentation of the data
/// flow without paying for them at runtime in shipped builds.
private let paginateLogger = Logger(subsystem: "chat.matron", category: "mac-chat-paginate")

/// Mac chat detail column. Hosts a `ScrollView` + `LazyVStack` of
/// `MacTimelineItemView` rows above the `MacComposerView`. Right-click
/// context menu replaces iOS's long-press; `⌘K` (hidden button) toggles
/// the slash palette without the user typing `/`. `⌘R` refresh is wired
/// via `NotificationCenter.matronCommand(.refresh)` (Task 14e attaches
/// the menu item; the listener stays attached even when the menu is
/// absent, so trackpad-only Macs without a hardware ⌘R can still drive
/// refresh once a binding lands).
///
/// Drag-and-drop attachments via `.onDrop(of: [.image, .fileURL], delegate:)`,
/// which routes through `ComposerDropDelegate → ComposerViewModel.attachFiles(_:)`
/// — same pipeline as the iOS PhotosPicker / fileImporter sites. The
/// security-scoped-resource bracketing the iOS `fileImporter` site
/// requires isn't needed here because the Mac sandbox grants drop URLs
/// transparent read access via the
/// `com.apple.security.files.user-selected.read-only` entitlement.
struct MacChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// App lifecycle — drives `viewModel.handleForeground()` so a
    /// background→foreground timeline re-sync doesn't flash the empty
    /// placeholder. See iOS `ChatView`.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Backing state for the right-click "View source" sheet (Task 16).
    /// `TimelineItem` is `Identifiable` (the SDK's stable
    /// `TimelineUniqueId.id`), so `.sheet(item:)` re-presents a fresh sheet
    /// when the user picks a different row.
    @State private var sourceItem: TimelineItem?
    /// Bottom-anchored visible item id, bound to `.scrollPosition` on
    /// the timeline ScrollView. Drives both the per-room scroll memory
    /// (so reopening a chat lands where the user left off) and the
    /// floating jump-to-latest button.
    @State private var scrolledItemID: String?
    /// Backing state for the fullscreen image preview. Files take a
    /// different path on Mac — `NSWorkspace.shared.open(_:)` hands
    /// the temp file to QuickLook / the user's preferred app, which
    /// means no SwiftUI sheet is needed. Only image taps land here.
    @State private var imagePreview: ImagePreview?

    /// Identifiable wrapper around a SwiftUI `Image` so
    /// `.sheet(item:)` has something to key on. Per-present UUID so
    /// two consecutive taps re-mount the sheet.
    fileprivate struct ImagePreview: Identifiable {
        let id = UUID()
        let image: Image
    }

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // QA finding #10: mirror the iOS error banner. Sliding-sync
            // timeouts now surface here instead of leaving the user
            // staring at an empty scroll view.
            if let errorMessage = viewModel.error {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.9))
                    .accessibilityLabel("Chat error: \(errorMessage)")
            }
            if viewModel.settledEmpty && viewModel.error == nil {
                // Settled-empty branch — see iOS `ChatView` and
                // `ChatViewModel.settledEmpty`. The debounced flag keeps
                // the placeholder from flashing on cold-start warm-up OR a
                // transient sliding-sync timeline reset.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                // `.equatable()` + the reference-identity `==` on
                // `MacTimelineListContent` is the scroll-perf fix — see
                // the iOS `ChatView` call site for the full rationale.
                // In short: the `.scrollPosition(id:)` binding below
                // writes `scrolledItemID` on every row crossing, each
                // write re-evaluates this body, and without the fence
                // that cascaded into every mounted row (~60% of
                // main-thread time in a scroll profile). Timeline
                // changes still propagate via `@Observable` tracking,
                // which invalidates the child directly.
                MacTimelineListContent(
                    viewModel: viewModel,
                    onPreviewImage: { imagePreview = ImagePreview(image: $0) },
                    onShowSource: { sourceItem = $0 }
                )
                .equatable()
            }
            // Warm-up state — see iOS `ChatView`: no rows yet but not
            // settled-empty, previously a fully blank message area. The
            // indicator delays its own appearance so cache-warm opens
            // never flash a spinner.
            .overlay {
                if viewModel.rows.isEmpty {
                    TimelineLoadingIndicator()
                }
            }
            // Mirror iOS — `.scrollPosition(id:)` binds the bottom-anchored
            // visible row id, which we use both for the per-room scroll
            // memory and for the jump-to-latest overlay.
            .scrollPosition(id: $scrolledItemID, anchor: .bottom)
            .onChange(of: viewModel.lastRenderableItemID) { oldID, newID in
                // Auto-follow the live tail only if the user was already
                // there. Scrolled-up users keep their position; the
                // floating button is the path back.
                guard let newID else { return }
                let wasAtTail = (scrolledItemID == oldID) || (scrolledItemID == nil)
                if wasAtTail {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        scrolledItemID = newID
                    }
                }
            }
            // Paginate when the visible bottom row enters the first
            // ~10 row ids (separators + messages combined). See iOS
            // ChatView for the full rationale: the scroll-position
            // binding uses mixed-namespace ids (messages → `item.id`,
            // separators → `"sep:<epoch>"`) so the prefix check has
            // to handle both.
            .onChange(of: scrolledItemID) { _, newID in
                guard let newID else { return }
                // `topRowIDs` is memoised on the view-model — this fires
                // on every scroll tick, and rebuilding the Set (plus the
                // per-tick diag log that used to live here) was measurable
                // scroll overhead.
                if viewModel.topRowIDs.contains(newID) {
                    Task { await viewModel.paginateBackward() }
                }
            }
            // "Loading earlier messages…" pill — see iOS `ChatView`
            // for the overlay rationale + `MinDisplayDuration`'s
            // role keeping fast-paginate flashes perceptible.
            .overlay(alignment: .top) {
                MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                    if visible {
                        PaginatingHeader()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
            }
            .overlay(alignment: .bottomTrailing) {
                if let last = viewModel.lastRenderableItemID, scrolledItemID != last {
                    JumpToBottomButton {
                        withAnimation(.easeOut(duration: 0.2)) {
                            scrolledItemID = last
                        }
                        ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
                    }
                }
            }
            }

            Divider()

            // Drag-and-drop attachments via ComposerDropDelegate.
            MacComposerView(viewModel: composerVM)
                .onDrop(
                    of: [.image, .fileURL],
                    delegate: ComposerDropDelegate(composer: composerVM)
                )
        }
        // matron-web's cream timeline gradient behind the whole chat
        // column — bubbles and the composer material share the warm ground.
        .background(MatronTimelineBackground())
        .toolbar {
            MacChatToolbar(
                title: chatTitle,
                onShowBotProfile: onShowBotProfile
            )
        }
        .task {
            // Restore the per-room scroll position BEFORE start() —
            // see iOS `ChatView` for the auto-follow guard rationale.
            scrolledItemID = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID)
            // `start()` (round-3 bugbot fix #3) returns once the first
            // timeline snapshot has been applied, so the chained
            // `markAsRead()` marks the actual head of the timeline as
            // read instead of racing the empty initial state.
            await viewModel.start()
            // Explicit paginate-on-open BEFORE markAsRead — see iOS
            // `ChatView`: history loads over HTTP and must not wait on
            // the live socket, which a half-dead connection can hang.
            await viewModel.paginateBackward()
            await viewModel.markAsRead()
        }
        .onDisappear {
            // Persist the user's scroll position so the next open of
            // this room lands where they left off; drop the entry on
            // tail so the default jump-to-tail behaviour applies.
            if let id = scrolledItemID, id != viewModel.lastRenderableItemID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
            viewModel.stop()
        }
        // ⌘K opens the slash palette without typing `/`. The hidden
        // button is the SwiftUI-recommended pattern for a global keyboard
        // shortcut that doesn't have a visible UI counterpart. Marked
        // accessibilityHidden because the unlabeled button would
        // otherwise be announced as a nameless "button" by VoiceOver
        // (QA finding #21).
        .background(
            Button("") { composerVM.palettePinnedOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
        // ⌘R refresh — driven by the menu-bar command bus (Task 14e).
        // When focus is on a chat detail column, ⌘R reloads THIS
        // chat's timeline (paginate-backward via
        // `ChatViewModel.refresh()`). The chat-list `⌘R` /
        // pull-to-refresh in `MacChatListView.refreshable` handles
        // the list-level snapshot via `ChatService.forceSnapshot()` —
        // those are different surfaces and stay separately wired.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.refresh))) { _ in
            Task { await viewModel.refresh() }
        }
        // ⌘K menu route — `Commands.swift` posts `.slashCommand` from
        // the Edit menu's "Slash Command" item. Without this listener
        // the menu route was dead (the keyboard shortcut still worked
        // via the hidden Button above, but the menu picked the same
        // notification and dropped it). QA finding #2.
        .onReceive(NotificationCenter.default.publisher(for: .matronCommand(.slashCommand))) { _ in
            composerVM.palettePinnedOpen.toggle()
        }
        .sheet(item: $sourceItem) { item in
            MacEventSourceSheet(item: item, onDismiss: { sourceItem = nil })
        }
        // Mac fullscreen image preview — Mac's `NSWorkspace.shared.open`
        // already owns the file path, so the only sheet wired here is
        // for the in-app pinch-zoom-style image viewer.
        .sheet(item: $imagePreview) { preview in
            AttachmentFullscreenViewer(
                image: preview.image,
                onDismiss: { imagePreview = nil }
            )
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                viewModel.handleForeground()
            }
        }
        // Mac mirror of iOS: fold cross-device ask-user answers into the
        // persisted set on every snapshot so resolved inline cards stay
        // resolved (bugbot "Cross-device answers not persisted").
        .onChange(of: viewModel.items) { _, _ in
            viewModel.persistVisibleAnswers()
        }
    }

}

/// The timeline's `LazyVStack` + `ForEach`, fenced off behind
/// `Equatable` so the parent's scroll-position `@State` churn can't
/// re-evaluate every mounted row (see the call site in
/// `MacChatView.body` and the iOS twin in `ChatView.swift`). `==`
/// compares only the view-model reference: row data is delivered
/// through `@Observable` tracking, which invalidates this view
/// directly when `viewModel.rows` (or anything else its body reads)
/// changes — the equatable check only gates parent-driven invalidation.
private struct MacTimelineListContent: View, Equatable {
    let viewModel: ChatViewModel
    let onPreviewImage: (Image) -> Void
    let onShowSource: (TimelineItem) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel
    }

    var body: some View {
        LazyVStack(spacing: 8) {
            // Render `rows` (messages interleaved with date
            // separators) instead of `items` directly. Mirrors
            // the iOS surface — the bucketing logic lives in
            // `ChatViewModel.rows` so the two platforms can't
            // drift.
            ForEach(viewModel.rows) { row in
                switch row {
                case .separator(let date):
                    DateSeparator(date: date)
                        .id(row.id)
                case .message(let item):
                    MacTimelineItemView(
                        item: item,
                        resolveImage: { viewModel.image(for: $0) },
                        onRetry: { id in viewModel.retrySend(itemID: id) },
                        onTapImage: { img in
                            onPreviewImage(img)
                        },
                        onTapFile: { mxc, filename in
                            Task {
                                if let url = await viewModel.writeTempFile(
                                    mxcURL: mxc, filename: filename
                                ) {
                                    // Hand off to the system —
                                    // QuickLook / the user's
                                    // chosen app handles the
                                    // open. Stays inside the
                                    // SwiftUI surface (no
                                    // need for a sheet on
                                    // Mac since the OS shell
                                    // owns the open path).
                                    await MainActor.run {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        },
                        askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                        isPromptAnswered: { viewModel.isPromptAnswered($0) },
                        answerSummary: { viewModel.answerSummary(forPrompt: $0) }
                    )
                        .id(item.id)
                        .onAppear {
                            let match = (item.id == viewModel.firstRenderableItemID)
                            paginateLogger.diag("onAppear: id=\(item.id) first=\(viewModel.firstRenderableItemID ?? "nil") match=\(match)")
                            if match {
                                Task { await viewModel.paginateBackward() }
                            }
                        }
                        .contextMenu {
                            if case .text(let body, _) = item.kind {
                                Button {
                                    Pasteboard.copy(body)
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                ShareLink(item: body) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                            }
                            // "View source" applies to every kind —
                            // text, image, file, stateChange, unknown
                            // — so it lives outside the `.text` guard.
                            Button {
                                onShowSource(item)
                            } label: {
                                Label("View source", systemImage: "curlybraces")
                            }
                        }
                }
            }
        }
        .scrollTargetLayout()
        .padding(.vertical)
    }
}


import SwiftUI
import MatronChat
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// iOS chat screen. Hosts a scrollable timeline (LazyVStack rendering each
/// `TimelineItem` via `TimelineItemView`) above a `ComposerView`. The
/// navigation toolbar shows the chat title and an info button that calls
/// `onShowBotProfile`.
///
/// `viewModel.start()` runs in `.task`; `viewModel.stop()` runs in
/// `.onDisappear` to release the AsyncStream's continuation. This mirrors
/// the `ChatListView` pattern from Phase 1.
///
/// Task 11 (journal rewire) drops the per-bot verification banner and its
/// SAS sheet — the journal stack has no per-bot identity-verification
/// concept.
struct ChatView: View {
    @State var viewModel: ChatViewModel
    @State var composerVM: ComposerViewModel
    /// App lifecycle — drives `viewModel.handleForeground()` so a
    /// background→foreground timeline re-sync doesn't flash the empty
    /// placeholder. `wasBackgrounded` filters out `.inactive`↔`.active`
    /// blips (notification centre, etc.) so only a real resume triggers it.
    @Environment(\.scenePhase) private var scenePhase
    @State private var wasBackgrounded = false
    /// Backing state for the "View source" sheet. `TimelineItem` is
    /// `Identifiable` (the SDK's stable `TimelineUniqueId.id`), so
    /// `.sheet(item:)` re-presents a fresh sheet whenever the user picks a
    /// different row instead of clinging to the prior one.
    @State private var sourceItem: TimelineItem?
    /// The bottom-anchored visible item id, bound to `.scrollPosition`
    /// on the timeline ScrollView. Drives both the per-room scroll
    /// memory (so reopening a chat lands where the user left off) and
    /// the floating "jump to latest" button (visible iff this isn't
    /// `items.last?.id`).
    @State private var scrolledItemID: String?
    /// Backing state for the fullscreen attachment preview. `nil`
    /// hides the sheet; setting either case presents it via
    /// `.sheet(item:)`. `.image` draws the pinch-zoom viewer; `.file`
    /// drives a small share sheet around `ShareLink(item:)` so the
    /// user can save / forward the attachment without leaving the
    /// chat.
    @State private var attachmentPreview: AttachmentPreview?
    /// Sheet payload for fullscreen attachment previews. Identifiable
    /// via a per-present UUID so two consecutive taps re-mount the
    /// sheet (and so `.sheet(item:)` doesn't conflate two separate
    /// images).
    fileprivate enum AttachmentPreview: Identifiable {
        case image(id: UUID = UUID(), Image)
        case file(id: UUID = UUID(), URL, filename: String)

        var id: UUID {
            switch self {
            case .image(let id, _): return id
            case .file(let id, _, _): return id
            }
        }
    }

    let chatTitle: String
    let onShowBotProfile: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // QA finding #10: surface upstream stream failures (e.g.
            // `SyncReadyError.timeout`) in a banner above the timeline
            // so the user understands why nothing is loading instead
            // of staring at an empty scroll view.
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
                // Settled-empty branch: gated on the debounced
                // `settledEmpty` (not raw `items.isEmpty`) so the
                // placeholder doesn't flash during sliding-sync warm-up
                // OR a transient timeline reset — both produce a
                // momentary empty `items` that repopulates within a tick.
                // See `ChatViewModel.settledEmpty`.
                EmptyChatPlaceholder(botName: chatTitle)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    // Render `rows` (messages interleaved with date
                    // separators) instead of `items` directly. The
                    // separator stream is computed on the view-model
                    // so iOS and Mac don't have to duplicate the
                    // calendar-day bucketing.
                    ForEach(viewModel.rows) { row in
                        switch row {
                        case .separator(let date):
                            DateSeparator(date: date)
                                .id(row.id)
                        case .message(let item):
                            TimelineItemView(
                                item: item,
                                resolveImage: { viewModel.image(for: $0) },
                                onRetry: { id in viewModel.retrySend(itemID: id) },
                                onTapImage: { img in
                                    attachmentPreview = .image(img)
                                },
                                onTapFile: { mxc, filename in
                                    Task {
                                        if let url = await viewModel.writeTempFile(
                                            mxcURL: mxc, filename: filename
                                        ) {
                                            attachmentPreview = .file(url, filename: filename)
                                        }
                                    }
                                },
                                askViewModel: { viewModel.askViewModel(forPrompt: $0) },
                                isPromptAnswered: { viewModel.isPromptAnswered($0) },
                                answerSummary: { viewModel.answerSummary(forPrompt: $0) }
                            )
                                .id(item.id)
                                // Infinite-scroll backward pagination
                                // trigger. Compares against
                                // `firstRenderableItemID` (the first
                                // non-`.stateChange` item) rather than
                                // `items.first?.id` — Matrix room
                                // timelines virtually always start
                                // with `.stateChange` rows (room
                                // create / encryption setup) that the
                                // view filters out, so the raw
                                // `items.first` comparison never
                                // matched any rendered row and
                                // scroll-up paginate silently never
                                // fired. See
                                // `ChatViewModel.firstRenderableItemID`
                                // for the full rationale.
                                .onAppear {
                                    if item.id == viewModel.firstRenderableItemID {
                                        Task { await viewModel.paginateBackward() }
                                    }
                                }
                                .contextMenu {
                                    if case .text(let body, _) = item.kind {
                                        Button {
                                            // Use the cross-platform helper from
                                            // MatronDesignSystem so iOS and Mac stay
                                            // on a single Pasteboard surface
                                            // (QA finding #3).
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
                                        sourceItem = item
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
            // Warm-up state: no rows yet, but not settled-empty either
            // (that's the branch above). This window used to render as a
            // fully blank message area while the first snapshot / history
            // fetch was in flight; the indicator's own appearance delay
            // keeps cache-warm opens spinner-free.
            .overlay {
                if viewModel.rows.isEmpty {
                    TimelineLoadingIndicator()
                }
            }
            // `.scrollPosition(id:anchor: .bottom)` binds `scrolledItemID`
            // to the row at the bottom of the viewport. Setting it to
            // `items.last?.id` jumps to the live tail; reading it tells
            // us which row the user is currently looking at, which is
            // both what we save for the per-room memory and what we
            // compare against the tail to decide whether to show the
            // jump-to-bottom button. `.scrollTargetLayout()` on the
            // `LazyVStack` is required for the binding to resolve row
            // ids.
            .scrollPosition(id: $scrolledItemID, anchor: .bottom)
            // Auto-follow the live tail only if the user was already at
            // the previous tail. If they've scrolled up to read history,
            // a new bot message shouldn't yank them back to the bottom —
            // that's what the floating jump button is for.
            .onChange(of: viewModel.lastRenderableItemID) { oldID, newID in
                guard let newID else { return }
                let wasAtTail = (scrolledItemID == oldID) || (scrolledItemID == nil)
                if wasAtTail {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        scrolledItemID = newID
                    }
                }
            }
            // Backward-pagination trigger driven by the scroll position
            // binding. The earlier `.onAppear` on the topmost row only
            // fires once per row mount and proved unreliable under
            // `.scrollPosition(id:)` — LazyVStack pre-mounts a buffer
            // of off-screen rows, so the first row's appear had often
            // already fired by the time the user actually scrolled to
            // it. `scrolledItemID` updates every time the visible row
            // at the bottom of the viewport changes, so this fires
            // continuously as the user scrolls. Paginate when the
            // visible bottom falls within the first 5 message ids —
            // i.e. user is within ~5 rows of the head, which is the
            // right time to fetch the next page.
            .onChange(of: scrolledItemID) { _, newID in
                guard let newID else { return }
                // The scroll-position binding uses whatever string was
                // attached via `.id(...)` on the matching row. Messages
                // use `item.id` directly; date-separator rows use the
                // `TimelineRow.id` ("sep:<epoch>") — mixed namespace.
                // Build a unified set of the first 10 row ids in
                // either form so the prefix check works for both.
                // Bumped from 5 → 10 so the trigger fires a few rows
                // BEFORE the user reaches the head, reducing perceived
                // jank as the next page arrives.
                let topRowIDs: Set<String> = Set(
                    viewModel.rows.prefix(10).map { row in
                        switch row {
                        case .message(let item): return item.id
                        case .separator: return row.id
                        }
                    }
                )
                if topRowIDs.contains(newID) {
                    Task { await viewModel.paginateBackward() }
                }
            }
            // "Loading earlier messages…" pill while a backward
            // paginate is in flight. Floats over the topmost content
            // (overlay rather than LazyVStack header) so its
            // appearance doesn't push the user's apparent reading
            // position around.
            //
            // `MinDisplayDuration` holds the visible flag `true` for
            // at least 500ms once shown — without it, a paginate
            // that completes from local cache (~50-200ms) finishes
            // before the 180ms fade-in animation, so the indicator
            // would either flash imperceptibly or get swallowed by
            // the fade-out entirely. Long paginates still show
            // throughout because the derived flag tracks `isActive`
            // immediately on the rising edge.
            .overlay(alignment: .top) {
                MinDisplayDuration(while: viewModel.isPaginatingBackward) { visible in
                    if visible {
                        PaginatingHeader()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: viewModel.isPaginatingBackward)
            }
            // Floating jump-to-latest. Visible only when the user has
            // scrolled away from the tail.
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
            ComposerView(viewModel: composerVM)
        }
        .navigationTitle(chatTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onShowBotProfile() } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .task {
            // Restore the per-room scroll position BEFORE start() so
            // the first snapshot's `.onChange` doesn't auto-pin to the
            // tail (its guard checks `scrolledItemID == oldID`, which
            // is true for the unrestored nil case but false once we've
            // set a saved id here). If no memory exists, `scrolledItemID`
            // stays nil and the chat opens at the tail as usual.
            scrolledItemID = ChatScrollPositionMemory.retrieve(roomID: viewModel.roomID)
            // Chain `markAsRead()` *after* the timeline observation has
            // applied its first snapshot. `start()` is now `async` and
            // returns once the first snapshot has landed (or the stream
            // ends without one), so the subsequent `markAsRead()` always
            // marks the actual head of the timeline as read instead of
            // racing the empty initial state. See `ChatViewModel.start()`
            // for the underlying signal mechanism (round-3 bugbot fix #3).
            await viewModel.start()
            // Explicit paginate-on-open BEFORE markAsRead. The store seeds
            // the timeline with whatever's mirrored locally (possibly
            // nothing, e.g. right after a snapshot_required wipe), so this
            // fetches the first page over HTTP; the topmost-row `.onAppear`
            // trigger handles SUBSEQUENT history loads as they scroll.
            // Ordered ahead of `markAsRead()` because that rides the live
            // socket — a half-dead socket can hang the send for its whole
            // timeout, and history loading must not wait on it.
            await viewModel.paginateBackward()
            await viewModel.markAsRead()
        }
        .onDisappear {
            // Capture the user's scroll position so the next open of
            // this room lands where they left off. Drop the entry on
            // tail (no point storing "user was at the live tail" — the
            // default behaviour already opens there).
            if let id = scrolledItemID, id != viewModel.lastRenderableItemID {
                ChatScrollPositionMemory.store(roomID: viewModel.roomID, itemID: id)
            } else {
                ChatScrollPositionMemory.forget(roomID: viewModel.roomID)
            }
            viewModel.stop()
        }
        .sheet(item: $sourceItem) { item in
            EventSourceSheet(item: item)
        }
        // Fullscreen attachment preview. Presented from a tap on
        // either an `AttachmentImage` or `AttachmentFile` row;
        // payload selects between the pinch-zoom image viewer and
        // the share-sheet wrapper for files. Dismissed by setting
        // `attachmentPreview = nil` (swipe-down on iOS, "Done"
        // button, or successful share).
        .sheet(item: $attachmentPreview) { preview in
            switch preview {
            case .image(_, let img):
                AttachmentFullscreenViewer(
                    image: img,
                    onDismiss: { attachmentPreview = nil }
                )
            case .file(_, let url, let filename):
                fileShareSheet(url: url, filename: filename)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                wasBackgrounded = true
            } else if newPhase == .active, wasBackgrounded {
                wasBackgrounded = false
                viewModel.handleForeground()
            }
        }
        // Persist cross-device ask-user answers the moment a snapshot
        // shows them, so a resolved inline card stays resolved even if a
        // later transient snapshot drops the answer event (bugbot
        // "Cross-device answers not persisted"). The old half-sheet
        // folded these inside `pendingAsk()`; the inline cards read
        // answered-state directly, so the fold is driven here.
        .onChange(of: viewModel.items) { _, _ in
            viewModel.persistVisibleAnswers()
        }
    }

    /// iOS file-share sheet body. Presents the filename + a system
    /// `ShareLink` so the user can save / forward the attachment
    /// without leaving the chat. Lifted into its own builder so the
    /// `.sheet(item:)` switch above stays tight.
    @ViewBuilder
    private func fileShareSheet(url: URL, filename: String) -> some View {
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
            Button("Done") { attachmentPreview = nil }
                .padding(.top, 4)
            Spacer()
        }
        .padding()
        .presentationDetents([.medium])
    }

}

